# frozen_string_literal: true

require "spec_helper"
require "json"

require_relative "../scripts/generate_matrix"

RSpec.describe MatrixGenerator do
  let(:generator) { described_class.new }

  let(:matrix_data) do
    {
      "ruby" => { "tidy" => %w[3.3.7 4.0.6], "full" => %w[3.1.6 3.3.7 4.0.6] },
      "env" => [
        { "host" => "ubuntu-22.04", "container" => "ubuntu-20.04", "os" => "linux-gnu", "arch" => "x86_64" },
        { "host" => "ubuntu-22.04", "container" => "ubuntu-20.04", "os" => "linux-gnu", "arch" => "arm64" },
        { "host" => "ubuntu-22.04", "container" => "alpine", "os" => "linux-musl", "arch" => "x86_64" },
        { "host" => "macos-15", "container" => nil, "os" => "macos", "arch" => "arm64" },
        { "host" => "windows-2022", "container" => nil, "os" => "windows", "arch" => "x86_64" }
      ]
    }
  end

  around do |example|
    old = %w[GITHUB_EVENT_NAME GITHUB_OUTPUT MATRIX_ENV_FILTER MATRIX_RUBY_FILTER]
          .to_h { |key| [key, ENV.fetch(key, nil)] }
    Dir.mktmpdir do |dir|
      @output = File.join(dir, "github_output")
      ENV["GITHUB_OUTPUT"] = @output
      example.run
    end
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def output_lines
    File.read(@output).lines.map(&:chomp)
  end

  describe "ruby version selection" do
    it "uses the tidy set for pull_request events" do
      ENV["GITHUB_EVENT_NAME"] = "pull_request"

      expect(generator.select_ruby_versions(matrix_data)).to eq(%w[3.3.7 4.0.6])
    end

    it "uses the full set for push and dispatch events" do
      %w[push workflow_dispatch schedule repository_dispatch].each do |event|
        ENV["GITHUB_EVENT_NAME"] = event
        expect(generator.select_ruby_versions(matrix_data)).to eq(%w[3.1.6 3.3.7 4.0.6])
      end
    end

    it "lets MATRIX_RUBY_FILTER pick a named set" do
      ENV["MATRIX_RUBY_FILTER"] = "tidy"

      expect(generator.select_ruby_versions(matrix_data)).to eq(%w[3.3.7 4.0.6])
    end

    it "lets MATRIX_RUBY_FILTER carry a comma-separated slice" do
      ENV["MATRIX_RUBY_FILTER"] = "3.3.7, 4.0.6"

      expect(generator.select_ruby_versions(matrix_data)).to eq(%w[3.3.7 4.0.6])
    end

    it "raises when the matrix.json section is missing" do
      ENV["GITHUB_EVENT_NAME"] = "pull_request"

      expect { generator.select_ruby_versions({ "ruby" => { "full" => [] } }) }
        .to raise_error(/No tidy section/)
    end
  end

  describe "env matrix filtering" do
    it "keeps every entry when the filter is empty or 'all'" do
      expect(generator.filter_env(matrix_data["env"])).to eq(matrix_data["env"])
      ENV["MATRIX_ENV_FILTER"] = "all"
      expect(generator.filter_env(matrix_data["env"])).to eq(matrix_data["env"])
    end

    it "selects a single os/arch pair" do
      ENV["MATRIX_ENV_FILTER"] = "linux-musl/x86_64"

      expect(generator.filter_env(matrix_data["env"]))
        .to eq([{ "host" => "ubuntu-22.04", "container" => "alpine",
                  "os" => "linux-musl", "arch" => "x86_64" }])
    end

    it "selects every arch of an os when no arch is given" do
      ENV["MATRIX_ENV_FILTER"] = "linux-gnu"

      expect(generator.filter_env(matrix_data["env"]).map { |entry| entry["arch"] })
        .to eq(%w[x86_64 arm64])
    end

    it "raises when the filter matches nothing" do
      ENV["MATRIX_ENV_FILTER"] = "plan9/pdp11"

      expect { generator.filter_env(matrix_data["env"]) }
        .to raise_error(%r{MATRIX_ENV_FILTER 'plan9/pdp11' matched no env entries})
    end
  end

  describe "workflow outputs" do
    it "writes the env matrix as a GITHUB_OUTPUT line" do
      ENV["MATRIX_ENV_FILTER"] = "windows/x86_64"

      generator.process_env_matrix(matrix_data)

      expect(output_lines).to eq(['env-matrix=[{"host":"windows-2022","container":null,' \
                                  '"os":"windows","arch":"x86_64"}]'])
    end

    it "writes the ruby matrix as a GITHUB_OUTPUT line" do
      ENV["GITHUB_EVENT_NAME"] = "pull_request"

      generator.process_ruby_matrix(matrix_data)

      expect(output_lines).to eq(['ruby-matrix=["3.3.7","4.0.6"]'])
    end

    it "appends both matrices to the same output file" do
      ENV["GITHUB_EVENT_NAME"] = "push"

      generator.process_env_matrix(matrix_data)
      generator.process_ruby_matrix(matrix_data)

      expect(output_lines.map { |line| line.split("=", 2).first }).to eq(%w[env-matrix ruby-matrix])
    end

    it "dumps the matrix.json content to the log when a stage fails" do
      ENV["MATRIX_ENV_FILTER"] = "plan9/pdp11"

      expect { generator.process_env_matrix(matrix_data) }
        .to raise_error(/matched no env entries/)
        .and output(/Error processing env matrix.*"linux-musl"/m).to_stdout
    end
  end

  describe "end-to-end run" do
    def write_matrix_json(dir, contents)
      FileUtils.mkdir_p(File.join(dir, ".github"))
      File.write(File.join(dir, ".github", "matrix.json"), contents)
    end

    it "produces both outputs from .github/matrix.json" do
      Dir.mktmpdir do |dir|
        write_matrix_json(dir, JSON.generate(matrix_data))
        ENV["GITHUB_EVENT_NAME"] = "push"

        Dir.chdir(dir) { described_class.new.run }

        expect(output_lines.map { |line| line.split("=", 2).first }).to eq(%w[env-matrix ruby-matrix])
      end
    end

    it "exits 1 when matrix.json is not valid JSON" do
      Dir.mktmpdir do |dir|
        write_matrix_json(dir, "{not json")

        expect { Dir.chdir(dir) { described_class.new.run } }
          .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end
    end

    it "exits 1 when matrix.json does not exist" do
      Dir.mktmpdir do |dir|
        expect { Dir.chdir(dir) { described_class.new.run } }
          .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end
    end
  end
end
