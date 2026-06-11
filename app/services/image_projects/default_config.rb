module ImageProjects
  class DefaultConfig
    def self.build(name:)
      {
        "projectName" => name,
        "layoutMode" => "strict",
        "canvasDefaults" => {
          "width" => 1650,
          "height" => 2480,
          "backgroundColor" => "#FAFAF0",
          "transparent" => false,
          "outputFormat" => "jpg"
        },
        "tasks" => [
          {
            "targetName" => "Task 1",
            "layoutMode" => "strict",
            "canvas" => {
              "width" => 1650,
              "height" => 2480,
              "backgroundColor" => "#FAFAF0",
              "transparent" => false
            },
            "output" => {
              "width" => 1650,
              "height" => 2480,
              "format" => "jpg"
            },
            "layers" => []
          }
        ]
      }
    end
  end
end
