require "json"

module PackageGraph
  APPROVED_INFRASTRUCTURE_DEPENDENCIES = ["Domain", "GRDB"].freeze

  module_function

  def violations(package)
    violations = []
    infrastructure_package = package.fetch("name").end_with?("Infrastructure")

    package.fetch("targets").each do |target|
      next unless target.fetch("type") == "regular"

      name = target.fetch("name")
      dependencies = target.fetch("dependencies").map do |dependency|
        dependency.values.first&.first
      end.compact

      case name
      when "Domain"
        dependencies.each do |dependency|
          violations << "#{name} must not depend on #{dependency}"
        end
      when "Application"
        dependencies.reject { |dependency| dependency == "Domain" }.each do |dependency|
          violations << "#{name} may only depend on Domain, not #{dependency}"
        end
      when /Feature\z/
        allowed_dependencies = ["Application", "DesignSystem", "Domain"]
        dependencies.reject { |dependency| allowed_dependencies.include?(dependency) }.each do |dependency|
          violations << "#{name} must not depend on #{dependency}"
        end
      end

      next unless infrastructure_package

      dependencies.reject do |dependency|
        APPROVED_INFRASTRUCTURE_DEPENDENCIES.include?(dependency)
      end.each do |dependency|
        violations << "#{name} must not depend on #{dependency}"
      end
    end

    violations
  end
end

if $PROGRAM_NAME == __FILE__
  package = JSON.parse($stdin.read)
  violations = PackageGraph.violations(package)

  unless violations.empty?
    warn "Invalid target dependency graph in #{package.fetch("name")}:"
    violations.each { |violation| warn "- #{violation}" }
    exit 1
  end
end
