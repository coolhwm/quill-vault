require "minitest/autorun"
require_relative "validate-package-graph"

class ValidatePackageGraphTest < Minitest::Test
  def test_feature_rejects_infrastructure_dependency
    package = package_named(
      "QuillvaultFeatures",
      target_named("HomeFeature", dependencies: ["AIClient"])
    )

    assert_equal(
      ["HomeFeature must not depend on AIClient"],
      PackageGraph.violations(package)
    )
  end

  def test_infrastructure_rejects_application_dependency_regardless_of_target_name
    package = package_named(
      "QuillvaultInfrastructure",
      target_named("MeetingFileStore", dependencies: ["Application"])
    )

    assert_equal(
      ["MeetingFileStore must not depend on Application"],
      PackageGraph.violations(package)
    )
  end

  def test_infrastructure_rejects_presentation_dependency
    package = package_named(
      "QuillvaultInfrastructure",
      target_named("MeetingFileStore", dependencies: ["DesignSystem"])
    )

    assert_equal(
      ["MeetingFileStore must not depend on DesignSystem"],
      PackageGraph.violations(package)
    )
  end

  def test_infrastructure_accepts_domain_and_approved_adapter_dependency
    package = package_named(
      "QuillvaultInfrastructure",
      target_named("PersistenceGRDB", dependencies: ["Domain", "GRDB"])
    )

    assert_empty(PackageGraph.violations(package))
  end

  def test_feature_accepts_only_the_documented_layers
    package = package_named(
      "QuillvaultFeatures",
      target_named(
        "RecordingFeature",
        dependencies: ["Application", "Domain", "DesignSystem"]
      )
    )

    assert_empty(PackageGraph.violations(package))
  end

  private

  def package_named(name, *targets)
    {"name" => name, "targets" => targets}
  end

  def target_named(name, dependencies:)
    {
      "name" => name,
      "type" => "regular",
      "dependencies" => dependencies.map do |dependency|
        {"byName" => [dependency, nil]}
      end,
    }
  end
end
