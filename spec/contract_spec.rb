# frozen_string_literal: true

require "spec_helper"
require "pathname"

require_relative "../scripts/check_contract_version"

# Roadmap 45: the release pipeline's contract.yml and the runtime driver's
# compiled-in TEBAKO_CONTRACT_VERSION are two representations of one
# contract; this class is the drift guard CI runs before the matrix builds.
RSpec.describe ContractVersionCheck do
  def with_fixtures(contract_body, driver_body)
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      contract = root.join("contract.yml")
      contract.write(contract_body)
      driver = root.join("tebako-main.cpp")
      driver.write(driver_body)
      yield described_class.new(contract_yml: contract, driver_src: driver)
    end
  end

  # The live-state guard is meaningful only where the v2 driver source is
  # checked out (CI sets TEBAKO_DRIVER_SRC to the product repo's
  # crates/tebako-driver/src/lib.rs). The class's build/src/tebako-main.cpp
  # fallback is the retired v1 generated file — a stale local build tree
  # must not turn the suite red.
  def with_live_driver
    skip "TEBAKO_DRIVER_SRC unset — the v2 driver lives in the tebako product repo" unless ENV["TEBAKO_DRIVER_SRC"]
    yield
  end

  it "the repo contract.yml validates against the schema and agrees with the driver" do
    with_live_driver do
      expect(described_class.new.errors).to be_empty
    end
  end

  it "reads both representations (bump-proof: never hardcode the value here)" do
    with_live_driver do
      check = described_class.new
      expect(check.yaml_version).to be_a(Integer)
      expect(check.driver_version).to eq(check.yaml_version)
    end
  end

  it "passes when the fixtures agree" do
    with_fixtures("contract_version: 2\n", "#define TEBAKO_CONTRACT_VERSION 2\n") do |check|
      expect(check.errors).to be_empty
    end
  end

  it "fails when the yaml and the compiled-in constant disagree, naming both" do
    with_fixtures("contract_version: 2\n", "#define TEBAKO_CONTRACT_VERSION 1\n") do |check|
      expect(check.errors).to contain_exactly(a_string_matching(/contract_version is 2.*TEBAKO_CONTRACT_VERSION.*is 1/))
    end
  end

  it "fails when the driver carries no compiled-in constant" do
    with_fixtures("contract_version: 1\n", "#define TEBAKO_LAUNCHER_ABI_VERSION 1u\n") do |check|
      expect(check.errors).to contain_exactly(a_string_matching(/carries no TEBAKO_CONTRACT_VERSION/))
    end
  end

  it "fails when contract.yml violates the schema" do
    with_fixtures("contract_version: one\n", "#define TEBAKO_CONTRACT_VERSION 1\n") do |check|
      expect(check.errors.size).to eq(1)
      expect(check.errors.first).to include("contract.yml")
    end
  end

  it "fails when contract.yml carries unknown keys" do
    with_fixtures("contract_version: 1\nother: 2\n", "#define TEBAKO_CONTRACT_VERSION 1\n") do |check|
      expect(check.errors).not_to be_empty
    end
  end
end
