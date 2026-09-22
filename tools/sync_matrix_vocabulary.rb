#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync .github/matrix.json's dispatch vocabulary (ruby.catalog / ruby.full /
# ruby.tidy) with the versions a tamatebako/ruby pin bump newly makes
# buildable.
#
# compute_matrix.rb reads the vocabulary verbatim (matrix_rubies) and the
# pin bump does not extend it — without this sync a catalog/full/tidy
# coordinator dispatch silently misses newly onboarded rubies (the 4.0.7
# gap: #182 landed the source, the vocabulary still stopped at 4.0.6).
#
#   tools/sync_matrix_vocabulary.rb OLD_VERSIONS_YML NEW_VERSIONS_YML
#
# DELTA MODE: only versions present in NEW but absent in OLD are admitted.
# The source factory's versions.yml carries every ruby it can roll (37+
# lines, including backfills the runtime factory deliberately never
# shipped); the runtime vocabulary is curated to published runtimes, so
# syncing against the full catalog would resurrect every skipped version.
# The delta between the two pinned refs is exactly what the bump newly
# offers — and the pin-bump PR's diff is the human review gate.
#
# catalog is additive — a published row never leaves. full/tidy move a
# line's tip only forward, and only for lines the set already carries:
# admitting a NEW minor line to full/tidy is a curation decision (CI cost,
# defer policy) that stays with the reviewer. Exits 0 without writing when
# the delta is empty or already covered. Named, loud failures — never a
# silent partial sync.

require "json"
require "yaml"

MATRIX = ".github/matrix.json"

def versions_from(file)
  data = YAML.safe_load_file(file)
  data.fetch("versions") { abort "#{file}: no versions: key" }
      .keys
      .grep(/\A\d+\.\d+\.\d+\z/)
      .sort_by { |v| Gem::Version.new(v) }
end

old_file = ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} OLD_VERSIONS_YML NEW_VERSIONS_YML" }
new_file = ARGV.fetch(1) { abort "usage: #{$PROGRAM_NAME} OLD_VERSIONS_YML NEW_VERSIONS_YML" }

old_versions = versions_from(old_file)
new_versions = versions_from(new_file)
abort "#{new_file}: no ruby versions found" if new_versions.empty?

delta = new_versions - old_versions
if delta.empty?
  puts "no new versions between the two pins (#{new_versions.last} is already known) -- vocabulary unchanged"
  exit 0
end

matrix = JSON.parse(File.read(MATRIX))
ruby = matrix.fetch("ruby") { abort "#{MATRIX}: no ruby key" }
%w[catalog full tidy].each do |set|
  ruby.fetch(set) { abort "#{MATRIX}: no ruby.#{set} array" }
end

line_of = ->(v) { v.split(".").first(2).join(".") }

# catalog: each new version lands after its line's last member (the
# vocabulary is line-grouped, oldest first).
catalog = ruby["catalog"]
added = []
delta.each do |v|
  next if catalog.include?(v)

  last = catalog.rindex { |e| line_of.call(e) == line_of.call(v) }
  catalog.insert(last ? last + 1 : catalog.length, v)
  added << v
end

# full/tidy: move a line's tip only when the delta carries a newer one for
# a line the set already tracks.
moved = []
%w[full tidy].each do |set|
  ruby[set].map! do |tip|
    newest = delta.select { |v| line_of.call(v) == line_of.call(tip) }.last
    if newest && Gem::Version.new(newest) > Gem::Version.new(tip)
      moved << "#{tip} -> #{newest} (#{set})"
      newest
    else
      tip
    end
  end
end

if added.empty? && moved.empty?
  puts "delta versions #{delta.join(', ')} already covered -- vocabulary unchanged"
  exit 0
end

File.write(MATRIX, JSON.pretty_generate(matrix) + "\n")
puts "vocabulary synced: catalog += [#{added.join(', ')}]; tips moved: #{moved.join(', ')}" \
     "#{added.empty? && moved.empty? ? ' (none)' : ''}"
