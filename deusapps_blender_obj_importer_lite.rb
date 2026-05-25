# DeusApps Blender OBJ Importer Lite v1.0.2 loader
# Root loader file for SketchUp Extension Manager.

require 'sketchup.rb'
require 'extensions.rb'

module DeusApps
  module BlenderOBJImporterLite
    EXTENSION_NAME = 'DeusApps Blender OBJ Importer Lite'.freeze
    EXTENSION_VERSION = '1.0.2'.freeze
    EXTENSION_FILE = 'deusapps_blender_obj_importer_lite/main'.freeze

    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new(EXTENSION_NAME, EXTENSION_FILE)
      extension.description = 'Geometry-only Blender OBJ importer for SketchUp. Clean import presets, orientation fixes, curve smoothing, and selected-geometry cleanup. Materials are intentionally ignored.'
      extension.version = EXTENSION_VERSION
      extension.creator = 'DeusApps'
      extension.copyright = 'Copyright 2026 DeusApps. All rights reserved.'

      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
