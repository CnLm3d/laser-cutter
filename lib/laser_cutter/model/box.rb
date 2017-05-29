require 'hashie/mash'
require 'forwardable'
require 'laser_cutter/helpers/shapes'
require 'laser_cutter/strategy/aggregator'
require 'laser_cutter/geometry/tuple/point'
module LaserCutter
  module Model
    # This +Box+ represents an assembly of lines that together create box faces
    # that can be printed on a printer, or cut on a laser-cutter. Each face
    # is represented by a set of lines that form "teeth" or "notches" for laser
    # cut boxes to snugly fit together in 3D.
    #
    # NOTE: Everything internally is in millimeters!
    class Box
      extend LaserCutter::Helpers::Shapes
      include LaserCutter::Helpers::Shapes

      # Configuration object
      attr_accessor :config

      # Dimensions of the box
      attr_accessor :dim

      # Here we forward a bunch of reader methods to the appropriate object.
      extend Forwardable
      def_delegators :@dim, :h, :w, :d
      def_delegators :@config, :thickness, :notch, :kerf, :padding, :units, :inner_box, :print_metadata

      # Internal Configuration
      attr_accessor :mapping

      # Calculated variables
      attr_accessor :bounds, :corner_face, :position_offset
      # reader is provided
      attr_writer :enclosure

      # +face+ is an array of the six faces of the box.
      attr_accessor :faces

      # +hf+ is an instance of a Hashie::Mash containing all faces,
      # keyed by the face name (symbol)
      #
      # eg: `[ hf.top, hf.bottom ]` or `[ hf[:top], hf[:bottom] ]`
      attr_accessor :faces_hash

      # A hash, keyed on the face name, eg :top, with values being a list of
      # Line objects that has been clean, sorted, and de-duped. It should be possible
      # to loop over each set of lines and use #line_to method to draw a point to the next one.
      attr_accessor :notches


      # This hash defines two variations on the strategy used to constructed the box.
      # One of the two variations is picked depending on the box dimensions.
      # Using this map we decide which of the box faces get to have the large
      # corners that "fill" the empty cube (with dimension of the material thickness) that is
      # necessarily created when three 3D parallelepiped shapes are joined at a corner.
      # Only one of the three dimensions must fill the corners, therefore only two
      # parallel faces must be set to include corners.
      #
      face_mapping_hash    = {
        face_order: [:top, :front, :bottom, :back, :left, :right],
        # determines whether the center notch in the middle is a notch (:out)
        # or a gap (:in)
        center_notch: {
          vertical:   [:out, :out, :out, :out, :in, :in],
          horizontal: [:in, :out, :in, :out, :in, :in],
        },

        corners:      {
          # our default choice, but may not work
          front: [:no, :yes, :no, :yes, :no, :no],
          # 2nd choice, has to work if 1st doesn't
          top: [:yes, :no, :yes, :no, :no, :no]
        },
      }
      DEFAULT_FACE_MAPPING = create(self) do
        hashie_mash(face_mapping_hash)
      end


      def initialize(config = nil)
        config = create(self) { hashie_mash } unless config

        self.dim = create(self) do
          dimensions(config.width,
                     config.height,
                     config.depth)
        end
        raise 'No DIM' unless dim && dim.d && self.d
        self.config          = config
        self.mapping         = DEFAULT_FACE_MAPPING
        self.faces           = []
        self.faces_hash      = hashie_mash
        self.notches         = hashie_mash
        self.position_offset = Geometry::Point::ORIGIN # default offset, could be changed later
        if block_given?
          yield(self)
          construct
        end
        @enclosure = nil
      end


      # Main __action__ method of the +Box+ class. Using all of the configuration information
      # that was passed to the constructor, having some additional parameters changed afterwards
      # (eg, possibly the offset), we ready to generate the notches.
      def construct
        unless faces_hash.empty?
          raise ArgumentError.new('The box has already been constructed')
        end

        # populate #hf hash with faces all starting at a [0,0].
        construct_faces

        # move faces to their true positions
        position_faces

        # chooses one of the three dimensions that will include the corner cube
        pick_corners_face

        # generates the notched lines for all faces.
        faces.size.times do |index|
          generate_lines_for_face(index)
        end

        generate_enclosure
        self
      end

      def enclosure
        @enclosure || generate_enclosure
      end

      def to_s
        "Box:\nH:#{dim.h} W:#{dim.w} D:#{dim.d}\nThickness:#{thickness}, Notch:#{notch}"
      end

      private

      # ______________________________________________________________________________________________
      # |                                                                                            |
      # |                                     PRIVATE METHODS                                        |
      # |____________________________________________________________________________________________|
      #


      def construct_faces
        zero_zero = Geometry::Point::ORIGIN
        matrix    = [
          [dim.w, dim.h, :front],
          [dim.w, dim.h, :back],
          [dim.w, dim.d, :top],
          [dim.w, dim.d, :bottom],
          [dim.d, dim.h, :left],
          [dim.d, dim.h, :right]
        ]
        matrix.each do |face_params|
          name                  = face_params.last
          self.faces_hash[name] = Geometry::Rect.create(zero_zero, *face_params)
        end

        # populates #faces, ordered based on #mapping[:face_order]
        self.faces = mapping[:face_order].map { |face_name| faces_hash[face_name] }
      end

      # Finds bounding box around all of the notches
      def generate_enclosure
        if notches[:top].nil? || notches[:top].empty?
          raise ArgumentError.new('Notches are not yet generated')
        end

        p1 = notches[:top].first.p1.to_a
        p2 = notches[:top].first.p2.to_a

        notches.keys.each do |face|
          notches[face].each do |notch|
            n = notch.normalized
            n.p1.to_a.each_with_index { |c, i| p1[i] = c if c < p1[i] }
            n.p2.to_a.each_with_index { |c, i| p2[i] = c if c > p2[i] }
          end
        end
        self.enclosure = create(self) { rectangle(point(p1), point(p2)) }
      end


      def face_bounding_rect(face)
        b = face.clone
        b.move_to(b.position.plus(-thickness, -thickness))
        b.p2 = b.p2.plus(2 * thickness, 2 * thickness)
        b.relocate!
      end

      #___________________________________________________________________
      #
      #               +-----------------+
      #               |                 |
      #               | back:     W x H |
      #               |                 |
      #               +-----------------+
      #               +-----------------+
      #               | bottom:   W x D |
      #               +-----------------+
      #   +--------+  +-----------------+  +--------+
      #   |        |  |                 |  |        |
      #   | left   |  | front:    W x H |  | right  |
      #   | D x H  |  |                 |  | D x H  |
      #   +--------+  X-----------------+  +--------+
      #               +-----------------+
      #               | top   :   W x D |
      #               +-----------------+
      #
      # 0,0
      #___________________________________________________________________

      def position_faces
        puts "padding: #{padding}\n"
        puts "thickness: #{thickness}\n"
        puts "position_offset: #{position_offset}\n"
        puts "d: #{d}\n"
        offset_x = [padding +
                      d +
                      3 * thickness,
                    position_offset.x +
                      2 * thickness +
                      padding].max
        offset_y = [padding + d + 3 * thickness, position_offset.y + 2 * thickness + padding].max

        # X Coordinate
        faces_hash.left.x  = offset_x - d - 2 * thickness - padding
        faces_hash.right.x = offset_x + w + 2 * thickness + padding

        [faces_hash.bottom, faces_hash.front, faces_hash.top, faces_hash.back].each { |s| s.x = offset_x }

        # Y Coordinate
        faces_hash.top.y    = offset_y - d - 2 * thickness - padding
        faces_hash.bottom.y = offset_y + h + 2 * thickness + padding
        faces_hash.back.y   = faces_hash.bottom.y + d + 2 * thickness + padding

        [faces_hash.left, faces_hash.front, faces_hash.right].each { |s| s.y = offset_y }

        faces.each(&:relocate!)
      end


      # Choose which face will be responsible for filling out the little square overlap
      # in the corners. Only one of the 3 possible sides need to be picked.
      def pick_corners_face
        self.corner_face = faces_hash[:front]
        b                = face_bounding_rect(corner_face)
        edges            = []
        self.corner_face.sides[0..1].each_with_index { |face, index| edges << edge(b.sides[index], face, notch: notch, kerf: kerf) }
        edges.map(&:notch_count).all? { |c| c % 4 == 3 } ? :top : :front
      end

      # Main logic method that creates four edges for each face. The logic is highly
      # stateful, and the index represents which face in the list we are working with.
      # Index's odd/even state, together with the #mapping controls whether the
      # middle of each edge is a notch or a gap, for example.
      def generate_lines_for_face(face_index)
        face  = faces[face_index]
        bound = face_bounding_rect(face)
        edges = [] # list of +Edge+ instances, four of them.

        bound.sides.each_with_index do |bounding_side, side_index|

          corners    = (self.mapping[:corners][corner_face.name][face_index] == :yes && side_index.odd?)
          center_out = center_is_notch_or_gap?(face_index, side_index)

          edges << create(self) do
            edge(bounding_side,
                 face.sides[side_index],
                 { :notch      => notch,
                   :thickness  => thickness,
                   :kerf       => kerf,
                   :center_out => center_out,
                   :corners    => corners
                 })
          end
        end

        # TODO: what the hell is this? Seems like a cludge fix that may not be in use.
        if edges.any? { |e| e.corners } && !edges.all? { |e| e.first_notch_out? }
          edges.each { |e| e.adjust_corners = true }
        end

        lines = []
        edges.each do |edge|
          lines << create(self) do
            path_finder(edge).generate
          end
        end

        self.notches[face.name.to_sym] ||= []
        self.notches[face.name.to_sym] = create(self) do
          aggregator(lines).dedup!.deoverlap!.lines.flatten.sort
        end

      end

      def center_is_notch_or_gap?(face_index, side_index)
        (self.mapping[:center_notch][side_index.odd? ? :vertical : :horizontal][face_index] == :out)
      end
    end
  end
end
