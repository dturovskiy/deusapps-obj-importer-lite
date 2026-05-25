# DeusApps Blender OBJ Importer Lite v1.0.2
#
# Geometry-only Wavefront OBJ importer for SketchUp.
#
# Developer:
#   DeusApps
#
# Menu:
#   Extensions -> DeusApps Blender OBJ Importer Lite
#
# Toolbar:
#   DeusApps OBJ Lite
#
# v1.0.2:
#   - Replaced generated toolbar icons with user-provided command icons:
#       Import, Smooth Curves, Clean Geometry.
#
# Materials are intentionally ignored to keep imported geometry predictable.

require 'sketchup.rb'

module DeusApps
  module BlenderOBJImporterLite

    PLUGIN_NAME = 'DeusApps Blender OBJ Importer Lite'.freeze
    VERSION = '1.0.2'.freeze
    PLUGIN_ID = 'DeusApps_BlenderOBJImporterLite'.freeze

    DEFAULT_SCALE = 39.37007874

    ORIENTATION_PRESETS = [
      'Direct XYZ',
      'Rotate 180 around X',
      'Rotate 180 around Y',
      'Rotate 180 around Z',
      'Swap Y/Z',
      'Swap Y/Z + Rotate 180 around X'
    ].freeze

    ImportSettings = Struct.new(
      :scale,
      :orientation_preset,
      :reverse_faces,

      :group_by_obj,
      :remove_collinear,
      :collinear_angle_deg,
      :min_edge_length,
      :min_face_area,

      :repair_failed_quads,
      :triangulate_all,
      :triangulate_rejected_ngons,
      :create_outline_edges,

      :one_parent_group,
      :soften_edges,
      :wall_angle_deg,
      :curve_angle_deg,
      :hide_softened_edges,
      keyword_init: true
    )

    FaceRecord = Struct.new(:indices, :source_line)

    class ImportStats
      attr_accessor :vertices_read,
                    :faces_created,
                    :faces_failed,
                    :faces_skipped,
                    :groups_created,
                    :triangles_created,
                    :quads_repaired,
                    :ngons_seen,
                    :duplicate_vertices_removed,
                    :short_edges_removed,
                    :collinear_vertices_removed,
                    :tiny_faces_rejected,
                    :ignored_material_lines,
                    :outline_edges_created,
                    :edges_softened,
                    :edges_hidden

      def initialize
        @vertices_read = 0
        @faces_created = 0
        @faces_failed = 0
        @faces_skipped = 0
        @groups_created = 0
        @triangles_created = 0
        @quads_repaired = 0
        @ngons_seen = 0
        @duplicate_vertices_removed = 0
        @short_edges_removed = 0
        @collinear_vertices_removed = 0
        @tiny_faces_rejected = 0
        @ignored_material_lines = 0
        @outline_edges_created = 0
        @edges_softened = 0
        @edges_hidden = 0
      end
    end

    class CleanStats
      attr_accessor :edges_seen,
                    :edges_softened,
                    :edges_hidden,
                    :loose_edges_erased,
                    :groups_seen,
                    :component_instances_seen

      def initialize
        @edges_seen = 0
        @edges_softened = 0
        @edges_hidden = 0
        @loose_edges_erased = 0
        @groups_seen = 0
        @component_instances_seen = 0
      end
    end

    def self.read_last_scale
      value = Sketchup.read_default(PLUGIN_ID, 'scale', DEFAULT_SCALE.to_s)
      parse_float(value, DEFAULT_SCALE)
    end

    def self.read_last_orientation
      value = Sketchup.read_default(PLUGIN_ID, 'orientation', 'Direct XYZ').to_s
      ORIENTATION_PRESETS.include?(value) ? value : 'Direct XYZ'
    end

    def self.write_last_settings(scale, orientation)
      Sketchup.write_default(PLUGIN_ID, 'scale', scale.to_s)
      Sketchup.write_default(PLUGIN_ID, 'orientation', orientation.to_s)
    rescue
    end

    def self.architectural_clean_settings
      ImportSettings.new(
        scale: read_last_scale,
        orientation_preset: read_last_orientation,
        reverse_faces: false,

        group_by_obj: true,
        remove_collinear: true,
        collinear_angle_deg: 0.25,
        min_edge_length: 0.001,
        min_face_area: 0.000001,

        repair_failed_quads: true,
        triangulate_all: false,
        triangulate_rejected_ngons: false,
        create_outline_edges: true,

        one_parent_group: true,
        soften_edges: true,
        wall_angle_deg: 2.0,
        curve_angle_deg: 25.0,
        hide_softened_edges: true
      )
    end

    def self.smooth_curves_settings
      settings = architectural_clean_settings
      settings.curve_angle_deg = 45.0
      settings
    end

    def self.clean_name(name, fallback = 'OBJ_Group')
      text = name.to_s.strip
      text = fallback if text.empty?
      text = text.gsub(/[^\w\.\-\s]+/, '_')
      text = text[0, 80]
      text.empty? ? fallback : text
    end

    def self.parse_float(text, fallback = 0.0)
      Float(text)
    rescue
      fallback
    end

    def self.parse_bool(text)
      text.to_s.strip.downcase.start_with?('y', 't', '1')
    end

    def self.choose_obj_file
      UI.openpanel('Import Blender OBJ Geometry', '', 'OBJ Files|*.obj||')
    end

    def self.import_blender_clean
      import_with_preset('Blender Architectural Clean', architectural_clean_settings)
    end

    def self.import_blender_smooth_curves
      import_with_preset('Blender Smooth Curves', smooth_curves_settings)
    end

    def self.import_with_preset(preset_name, settings)
      path = choose_obj_file
      return unless path

      prompts = [
        'Scale multiplier',
        'Orientation preset',
        'Reverse face winding? yes/no'
      ]

      defaults = [
        settings.scale.to_s,
        settings.orientation_preset,
        'no'
      ]

      lists = [
        '',
        ORIENTATION_PRESETS.join('|'),
        'yes|no'
      ]

      input = UI.inputbox(prompts, defaults, lists, "#{preset_name} - Import Options")
      return unless input

      settings.scale = parse_float(input[0], DEFAULT_SCALE)
      settings.orientation_preset = input[1].to_s
      settings.reverse_faces = parse_bool(input[2])

      write_last_settings(settings.scale, settings.orientation_preset)

      begin
        stats = import_obj_geometry_only(path, settings)
        show_import_stats(stats, preset_name, settings.orientation_preset)
      rescue => e
        show_error('OBJ import failed', e)
      end
    end

    def self.show_import_stats(stats, preset_name, orientation)
      UI.messagebox(
        "OBJ geometry import finished.\n" \
        "Preset: #{preset_name}\n" \
        "Orientation: #{orientation}\n\n" \
        "Vertices read: #{stats.vertices_read}\n" \
        "Faces created: #{stats.faces_created}\n" \
        "Triangles created: #{stats.triangles_created}\n" \
        "Quads repaired: #{stats.quads_repaired}\n" \
        "N-gons seen: #{stats.ngons_seen}\n" \
        "Faces skipped/rejected: #{stats.faces_skipped}\n" \
        "Faces failed: #{stats.faces_failed}\n" \
        "Tiny faces rejected: #{stats.tiny_faces_rejected}\n" \
        "Outline edges created: #{stats.outline_edges_created}\n" \
        "Groups created: #{stats.groups_created}\n" \
        "Duplicate vertices removed: #{stats.duplicate_vertices_removed}\n" \
        "Short edges removed: #{stats.short_edges_removed}\n" \
        "Collinear vertices removed: #{stats.collinear_vertices_removed}\n" \
        "Material lines ignored: #{stats.ignored_material_lines}\n" \
        "Edges softened: #{stats.edges_softened}\n" \
        "Edges hidden: #{stats.edges_hidden}\n\n" \
        "Materials are intentionally not imported."
      )
    end

    def self.show_error(title, error)
      UI.messagebox(
        "#{title}:\n\n" \
        "#{error.class}: #{error.message}\n\n" \
        "#{error.backtrace[0, 10].join("\n")}"
      )
    end

    def self.apply_orientation(x, y, z, preset)
      case preset
      when 'Direct XYZ'
        [x, y, z]
      when 'Rotate 180 around X'
        [x, -y, -z]
      when 'Rotate 180 around Y'
        [-x, y, -z]
      when 'Rotate 180 around Z'
        [-x, -y, z]
      when 'Swap Y/Z'
        [x, z, y]
      when 'Swap Y/Z + Rotate 180 around X'
        [x, -z, -y]
      else
        [x, y, z]
      end
    end

    def self.transform_point(x, y, z, settings)
      ox, oy, oz = apply_orientation(x, y, z, settings.orientation_preset)
      Geom::Point3d.new(ox * settings.scale, oy * settings.scale, oz * settings.scale)
    end

    def self.resolve_obj_index(raw_index, vertex_count)
      index = raw_index.to_i
      index < 0 ? vertex_count + index : index - 1
    end

    def self.parse_face_vertex_token(token, vertex_count)
      raw = token.split('/')[0]
      resolve_obj_index(raw, vertex_count)
    end

    def self.valid_indices?(indices, vertex_count)
      indices.all? { |index| !index.nil? && index >= 0 && index < vertex_count }
    end

    def self.group_key(current_group_name, group_by_obj)
      group_by_obj ? clean_name(current_group_name, 'OBJ_Group') : 'OBJ_Geometry'
    end

    def self.parse_obj_file(path, settings, stats)
      vertices = []
      grouped_faces = Hash.new { |hash, key| hash[key] = [] }
      current_group_name = File.basename(path, File.extname(path))

      File.foreach(path).with_index(1) do |line, line_number|
        line = line.strip
        next if line.empty?
        next if line.start_with?('#')

        parts = line.split(/\s+/)
        key = parts[0].downcase

        case key
        when 'v'
          x = parse_float(parts[1])
          y = parse_float(parts[2])
          z = parse_float(parts[3])
          vertices << transform_point(x, y, z, settings)

        when 'o', 'g'
          if settings.group_by_obj
            name = parts[1..-1].join(' ').strip
            current_group_name = name unless name.empty?
          end

        when 'f'
          next if parts.length < 4

          indices = parts[1..-1].map { |token| parse_face_vertex_token(token, vertices.length) }

          unless valid_indices?(indices, vertices.length)
            stats.faces_failed += 1
            next
          end

          indices = compact_duplicate_indices(indices, stats)

          if indices.length < 3
            stats.faces_failed += 1
            next
          end

          stats.ngons_seen += 1 if indices.length > 4
          grouped_faces[group_key(current_group_name, settings.group_by_obj)] << FaceRecord.new(indices, line_number)

        when 'mtllib', 'usemtl'
          stats.ignored_material_lines += 1
        end
      end

      stats.vertices_read = vertices.length
      [vertices, grouped_faces]
    end

    def self.compact_duplicate_indices(indices, stats)
      compact = []

      indices.each do |index|
        if compact.empty? || compact[-1] != index
          compact << index
        else
          stats.duplicate_vertices_removed += 1
        end
      end

      if compact.length > 1 && compact.first == compact.last
        compact.pop
        stats.duplicate_vertices_removed += 1
      end

      seen = {}
      simple = []

      compact.each do |index|
        unless seen[index]
          simple << index
          seen[index] = true
        else
          stats.duplicate_vertices_removed += 1
        end
      end

      simple
    end

    def self.distance_between(point_a, point_b)
      point_a.distance(point_b)
    rescue
      (point_a - point_b).length
    end

    def self.triangle_area_points(a, b, c)
      ab = b - a
      ac = c - a
      0.5 * ab.cross(ac).length
    rescue
      0.0
    end

    def self.polygon_area_points(points)
      return 0.0 if points.length < 3

      origin = points[0]
      area = 0.0

      (1...(points.length - 1)).each do |index|
        area += triangle_area_points(origin, points[index], points[index + 1])
      end

      area
    end

    def self.remove_short_edges(points, indices, min_edge_length, stats)
      return indices if min_edge_length <= 0.0
      return indices if indices.length < 3

      changed = true
      result = indices.dup

      while changed && result.length >= 3
        changed = false
        output = []

        result.each_with_index do |index, i|
          prev_index = result[(i - 1) % result.length]
          curr_point = points[index]
          prev_point = points[prev_index]

          if distance_between(prev_point, curr_point) < min_edge_length
            stats.short_edges_removed += 1
            changed = true
            next
          end

          output << index
        end

        result = output
      end

      result
    end

    def self.angle_between_vectors(v1, v2)
      v1.angle_between(v2)
    rescue
      Math::PI
    end

    def self.remove_collinear_vertices(points, indices, angle_tolerance_deg, stats)
      return indices if angle_tolerance_deg <= 0.0
      return indices if indices.length <= 3

      tolerance = angle_tolerance_deg.to_f * Math::PI / 180.0
      result = indices.dup
      changed = true

      while changed && result.length > 3
        changed = false
        output = []

        result.each_with_index do |index, i|
          prev_index = result[(i - 1) % result.length]
          next_index = result[(i + 1) % result.length]

          prev_point = points[prev_index]
          curr_point = points[index]
          next_point = points[next_index]

          v1 = prev_point - curr_point
          v2 = next_point - curr_point

          if v1.length <= 0.0 || v2.length <= 0.0
            stats.collinear_vertices_removed += 1
            changed = true
            next
          end

          angle = angle_between_vectors(v1, v2)

          if (Math::PI - angle).abs <= tolerance
            stats.collinear_vertices_removed += 1
            changed = true
            next
          end

          output << index
        end

        result = output
      end

      result
    end

    def self.clean_face_indices(points, indices, settings, stats)
      result = remove_short_edges(points, indices, settings.min_edge_length, stats)
      result = remove_collinear_vertices(points, result, settings.collinear_angle_deg, stats) if settings.remove_collinear
      result
    end

    def self.create_parent_entities(model, path, one_parent_group)
      return model.entities unless one_parent_group

      parent = model.entities.add_group
      parent.name = clean_name(File.basename(path, File.extname(path)), 'OBJ_Import')
      parent.entities
    end

    def self.make_group(parent_entities, name)
      group = parent_entities.add_group
      group.name = clean_name(name, 'OBJ_Group')
      group
    end

    def self.add_face_direct(entities, points, reverse_faces)
      face_points = reverse_faces ? points.reverse : points
      face = nil

      begin
        face = entities.add_face(face_points)
      rescue
        face = nil
      end

      if face.nil?
        begin
          face = entities.add_face(face_points.reverse)
        rescue
          face = nil
        end
      end

      face
    end

    def self.add_outline_edges(entities, points)
      created = 0
      return created if points.length < 2

      loop_points = points + [points.first]

      (0...(loop_points.length - 1)).each do |index|
        begin
          edge = entities.add_line(loop_points[index], loop_points[index + 1])
          created += 1 if edge
        rescue
        end
      end

      created
    end

    def self.triangulate_face_fan(entities, points, reverse_faces)
      face_points = reverse_faces ? points.reverse : points
      created = 0
      return created if face_points.length < 3

      base = face_points[0]

      (1...(face_points.length - 1)).each do |index|
        tri = [base, face_points[index], face_points[index + 1]]
        face = add_face_direct(entities, tri, false)
        created += 1 if face
      end

      created
    end

    def self.triangle_quality(a, b, c)
      area = triangle_area_points(a, b, c)
      edges = [
        distance_between(a, b),
        distance_between(b, c),
        distance_between(c, a)
      ]

      max_edge = edges.max
      return 0.0 if max_edge.nil? || max_edge <= 0.0

      area / (max_edge * max_edge)
    end

    def self.try_quad_split(entities, points, reverse_faces)
      return 0 unless points.length == 4

      p0, p1, p2, p3 = points

      candidates = [
        [[p0, p1, p2], [p0, p2, p3]],
        [[p1, p2, p3], [p1, p3, p0]]
      ]

      scored = candidates.map do |pair|
        quality = triangle_quality(pair[0][0], pair[0][1], pair[0][2]) +
                  triangle_quality(pair[1][0], pair[1][1], pair[1][2])
        [quality, pair]
      end

      scored.sort! { |a, b| b[0] <=> a[0] }

      scored.each do |score, pair|
        next if score <= 0.0

        temp_created = []
        ok = true

        pair.each do |tri|
          face = add_face_direct(entities, tri, reverse_faces)
          if face
            temp_created << face
          else
            ok = false
            break
          end
        end

        return temp_created.length if ok

        temp_created.each do |face|
          begin
            face.erase! if face.valid?
          rescue
          end
        end
      end

      0
    end

    def self.add_face_safely(entities, points, settings, stats)
      if points.length < 3
        stats.faces_failed += 1
        return 0
      end

      area = polygon_area_points(points)
      if settings.min_face_area > 0.0 && area < settings.min_face_area
        stats.tiny_faces_rejected += 1
        stats.faces_skipped += 1
        return 0
      end

      if settings.triangulate_all
        created = triangulate_face_fan(entities, points, settings.reverse_faces)
        stats.triangles_created += created
        stats.faces_created += created if created > 0
        return created
      end

      face = add_face_direct(entities, points, settings.reverse_faces)
      if face
        stats.faces_created += 1
        return 1
      end

      if settings.repair_failed_quads && points.length == 4
        created = try_quad_split(entities, points, settings.reverse_faces)
        if created > 0
          stats.quads_repaired += 1
          stats.triangles_created += created
          stats.faces_created += created
          return created
        end
      end

      if settings.triangulate_rejected_ngons && points.length > 4
        created = triangulate_face_fan(entities, points, settings.reverse_faces)
        if created > 0
          stats.triangles_created += created
          stats.faces_created += created
          return created
        end
      end

      if settings.create_outline_edges
        stats.outline_edges_created += add_outline_edges(entities, points)
      end

      stats.faces_skipped += 1
      0
    end

    def self.edge_angle(edge)
      faces = edge.faces
      return nil unless faces.length == 2

      begin
        faces[0].normal.angle_between(faces[1].normal)
      rescue
        nil
      end
    end

    def self.soften_edges_by_angles(entities, wall_angle_deg, curve_angle_deg, hide_edges, stats)
      wall_angle = wall_angle_deg.to_f * Math::PI / 180.0
      curve_angle = curve_angle_deg.to_f * Math::PI / 180.0

      entities.each do |entity|
        next unless entity.is_a?(Sketchup::Edge)
        next unless entity.valid?

        angle = edge_angle(entity)
        next if angle.nil?

        should_soften = angle <= curve_angle
        should_hide = hide_edges && angle <= wall_angle

        next unless should_soften

        begin
          entity.soft = true if entity.respond_to?(:soft=)
          entity.smooth = true if entity.respond_to?(:smooth=)
          stats.edges_softened += 1

          if should_hide
            entity.hidden = true
            stats.edges_hidden += 1
          end
        rescue
        end
      end
    end

    def self.build_geometry(parent_entities, vertices, grouped_faces, settings, stats)
      grouped_faces.each do |group_name, records|
        group = make_group(parent_entities, group_name)
        stats.groups_created += 1

        records.each do |record|
          indices = clean_face_indices(vertices, record.indices, settings, stats)

          if indices.length < 3
            stats.faces_failed += 1
            next
          end

          points = indices.map { |index| vertices[index] }
          add_face_safely(group.entities, points, settings, stats)
        end

        if settings.soften_edges
          soften_edges_by_angles(
            group.entities,
            settings.wall_angle_deg,
            settings.curve_angle_deg,
            settings.hide_softened_edges,
            stats
          )
        end

        begin
          group.erase! if group.valid? && group.entities.count == 0
        rescue
        end
      end
    end

    def self.import_obj_geometry_only(path, settings)
      model = Sketchup.active_model
      stats = ImportStats.new

      vertices, grouped_faces = parse_obj_file(path, settings, stats)

      model.start_operation('DeusApps Blender OBJ Import', true)

      begin
        parent_entities = create_parent_entities(model, path, settings.one_parent_group)
        build_geometry(parent_entities, vertices, grouped_faces, settings, stats)

        model.commit_operation
        stats
      rescue => e
        model.abort_operation
        raise e
      end
    end

    def self.clean_selected_geometry_dialog
      prompts = [
        'Wall coplanar angle degrees',
        'Curve smoothing angle degrees',
        'Hide coplanar internal edges? yes/no',
        'Erase loose edges shorter than inches',
        'Process nested groups/components? yes/no'
      ]

      defaults = [
        '2.0',
        '35.0',
        'yes',
        '0.001',
        'yes'
      ]

      input = UI.inputbox(prompts, defaults, 'Clean Selected Geometry')
      return unless input

      wall_angle_deg = parse_float(input[0], 2.0)
      curve_angle_deg = parse_float(input[1], 35.0)
      hide_coplanar = parse_bool(input[2])
      erase_loose_threshold = parse_float(input[3], 0.001)
      recursive = parse_bool(input[4])

      begin
        stats = clean_selected_geometry(
          wall_angle_deg,
          curve_angle_deg,
          hide_coplanar,
          erase_loose_threshold,
          recursive
        )

        UI.messagebox(
          "Clean Selected Geometry finished.\n\n" \
          "Edges seen: #{stats.edges_seen}\n" \
          "Edges softened: #{stats.edges_softened}\n" \
          "Edges hidden: #{stats.edges_hidden}\n" \
          "Loose short edges erased: #{stats.loose_edges_erased}\n" \
          "Groups seen: #{stats.groups_seen}\n" \
          "Component instances seen: #{stats.component_instances_seen}"
        )
      rescue => e
        show_error('Clean Selected Geometry failed', e)
      end
    end

    def self.clean_selected_geometry(wall_angle_deg, curve_angle_deg, hide_coplanar, erase_loose_threshold, recursive)
      model = Sketchup.active_model
      selection = model.selection

      if selection.empty?
        UI.messagebox('Select imported geometry, groups, or components first.')
        return CleanStats.new
      end

      stats = CleanStats.new

      model.start_operation('DeusApps Clean Selected Geometry', true)

      begin
        selection.each do |entity|
          clean_entity(entity, wall_angle_deg, curve_angle_deg, hide_coplanar, erase_loose_threshold, recursive, stats)
        end

        model.commit_operation
        stats
      rescue => e
        model.abort_operation
        raise e
      end
    end

    def self.clean_entity(entity, wall_angle_deg, curve_angle_deg, hide_coplanar, erase_loose_threshold, recursive, stats)
      if entity.is_a?(Sketchup::Edge)
        clean_edge(entity, wall_angle_deg, curve_angle_deg, hide_coplanar, erase_loose_threshold, stats)
      elsif entity.is_a?(Sketchup::Group)
        stats.groups_seen += 1
        clean_entities(entity.entities, wall_angle_deg, curve_angle_deg, hide_coplanar, erase_loose_threshold, recursive, stats) if recursive
      elsif entity.is_a?(Sketchup::ComponentInstance)
        stats.component_instances_seen += 1
        clean_entities(entity.definition.entities, wall_angle_deg, curve_angle_deg, hide_coplanar, erase_loose_threshold, recursive, stats) if recursive
      end
    end

    def self.clean_entities(entities, wall_angle_deg, curve_angle_deg, hide_coplanar, erase_loose_threshold, recursive, stats)
      entities.to_a.each do |entity|
        clean_entity(entity, wall_angle_deg, curve_angle_deg, hide_coplanar, erase_loose_threshold, recursive, stats)
      end
    end

    def self.clean_edge(edge, wall_angle_deg, curve_angle_deg, hide_coplanar, erase_loose_threshold, stats)
      return unless edge.valid?

      stats.edges_seen += 1

      if edge.faces.empty? && erase_loose_threshold > 0.0
        begin
          if edge.length < erase_loose_threshold
            edge.erase!
            stats.loose_edges_erased += 1
            return
          end
        rescue
        end
      end

      angle = edge_angle(edge)
      return if angle.nil?

      wall_angle = wall_angle_deg.to_f * Math::PI / 180.0
      curve_angle = curve_angle_deg.to_f * Math::PI / 180.0

      should_soften = angle <= curve_angle
      should_hide = hide_coplanar && angle <= wall_angle

      return unless should_soften

      begin
        edge.soft = true if edge.respond_to?(:soft=)
        edge.smooth = true if edge.respond_to?(:smooth=)
        stats.edges_softened += 1

        if should_hide
          edge.hidden = true
          stats.edges_hidden += 1
        end
      rescue
      end
    end

    def self.about
      UI.messagebox(
        "#{PLUGIN_NAME} v#{VERSION}\n\n" \
        "Developer: DeusApps\n\n" \
        "Lite edition.\n" \
        "Geometry-only Blender OBJ importer for SketchUp.\n" \
        "Materials and textures are intentionally ignored.\n\n" \
        "v1.0.2 uses user-provided toolbar icons."
      )
    end

    def self.quick_help
      UI.messagebox(
        "Quick workflow:\n\n" \
        "1. In Blender export OBJ:\n" \
        "   Selection Only ON\n" \
        "   Apply Modifiers ON\n" \
        "   Write Materials OFF\n\n" \
        "2. In SketchUp use:\n" \
        "   Import Blender OBJ...\n\n" \
        "3. For cylinders/curves use:\n" \
        "   Import Blender OBJ - Smooth Curves...\n\n" \
        "4. After import select the model and run:\n" \
        "   Clean Selected Geometry..."
      )
    end

    def self.icon_path(name, size)
      File.join(File.dirname(__FILE__), 'icons', "#{name}_#{size}.png")
    end

    def self.setup_ui
      menu = UI.menu('Extensions')
      submenu = menu.add_submenu('DeusApps Blender OBJ Importer Lite')

      import_cmd = UI::Command.new('Import Blender OBJ...') do
        import_blender_clean
      end
      import_cmd.tooltip = 'Import Blender OBJ geometry'
      import_cmd.status_bar_text = 'Import Blender OBJ as clean SketchUp geometry.'
      import_cmd.small_icon = icon_path('import_v102', 16)
      import_cmd.large_icon = icon_path('import_v102', 24)

      smooth_cmd = UI::Command.new('Import Blender OBJ - Smooth Curves...') do
        import_blender_smooth_curves
      end
      smooth_cmd.tooltip = 'Import Blender OBJ with stronger curve smoothing'
      smooth_cmd.status_bar_text = 'Use for cylinders, pipes, round/oval objects.'
      smooth_cmd.small_icon = icon_path('smooth_v102', 16)
      smooth_cmd.large_icon = icon_path('smooth_v102', 24)

      clean_cmd = UI::Command.new('Clean Selected Geometry...') do
        clean_selected_geometry_dialog
      end
      clean_cmd.tooltip = 'Clean selected imported geometry'
      clean_cmd.status_bar_text = 'Soften/hide internal edges and clean short loose edges.'
      clean_cmd.small_icon = icon_path('clean_v102', 16)
      clean_cmd.large_icon = icon_path('clean_v102', 24)

      submenu.add_item(import_cmd)
      submenu.add_item(smooth_cmd)
      submenu.add_separator
      submenu.add_item(clean_cmd)
      submenu.add_separator
      submenu.add_item('Quick Help') { quick_help }
      submenu.add_item('About') { about }

      toolbar = UI::Toolbar.new('DeusApps OBJ Lite')
      toolbar.add_item(import_cmd)
      toolbar.add_item(smooth_cmd)
      toolbar.add_item(clean_cmd)
      toolbar.restore
    end

    unless file_loaded?(__FILE__)
      setup_ui
      file_loaded(__FILE__)
    end

  end
end
