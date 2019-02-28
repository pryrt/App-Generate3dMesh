package CAD::Mesh3D;
use warnings;
use strict;
use Carp;
use 5.010;  # M::V::R requires 5.010, so might as well make use of the defined-or // notation :-)
use Math::Vector::Real 0.18;
use CAD::Format::STL qw//;
our $VERSION = 0.001_011;

=head1 NAME

CAD::Mesh3D - Create and Manipulate 3D Vertices and Meshes and output for 3D printing

=head1 SYNOPSIS

 use CAD::Mesh3D qw(+STL :create :output);
 my $vect = createVertex();
 my $tri  = createFacet($v1, $v2, $v3);
 my $mesh = createMesh();
 addToMesh($mesh, $tri);
 push @$mesh, $tri;               # manual method of addToMesh()
 ...
 output($mesh, STL => $filehandle_or_filename, $true_for_ascii_false_for_binary);

=head1 DESCRIPTION

A framework to create and manipulate 3D vertices and meshes, suitable for generating STL files
(or other similar formats) for 3D printing.

A B<Mesh> is the container for the surface of the shape or object being generated.  The surface is broken down
into locally-flat pieces known as B<Facet>s.  Each Facet is a triangle made from exactly points, called
B<Vertex>es or vertices.  Each Vertex is made up of three x, y, and z B<coordinate>s, which are just
floating-point values to represent the position in 3D space.

=cut

################################################################
# Exports
################################################################

use Exporter 5.57 ();     # v5.57 needed for getting import() without @ISA         # use Exporter 5.57 'import';
our @ISA = qw/Exporter/;
our @EXPORT_CREATE  = qw(createVertex createFacet createQuadrangleFacets createMesh addToMesh);
our @EXPORT_VERTEX  = qw(createVertex getx gety getz);
our @EXPORT_MATH    = qw(unitDelta unitCross facetNormal);
our @EXPORT_FORMATS = qw(enableFormat output input);
our @EXPORT_OK      = (@EXPORT_CREATE, @EXPORT_MATH, @EXPORT_FORMATS, @EXPORT_VERTEX);
our @EXPORT         = @EXPORT_FORMATS;
our %EXPORT_TAGS = (
    create          => \@EXPORT_CREATE,
    vertex          => \@EXPORT_VERTEX,
    math            => \@EXPORT_MATH,
    formats         => \@EXPORT_FORMATS,
    all             => \@EXPORT_OK,
);

sub import
{
    my @list = @_;
    my @passthru;

    # pass most arguments thru, but if it starts with +, then try to enable that format
    foreach my $arg (@list) {
        if( $arg =~ /^\+/ ) {
            $arg =~ s/^\+//;
            enableFormat($arg);
            next;
        }
        push @passthru, $arg;
    }
    CAD::Mesh3D->export_to_level(1, @passthru);
}

################################################################
# "object" creation
################################################################
use constant { XCOORD=>0, YCOORD=>1, ZCOORD=>2 }; # avoid magic numbers

################################################################
# "object" creation
################################################################
# TODO = make the error checking into self-contained routines -- there's
#   too much duplicated work

=head1 FUNCTIONS

=head2 OBJECT CREATION

The following functions will create the B<Mesh>, B<Triangle>, and B<Vertex> array-references.
They can be imported into your script I<en masse> using the C<:create> tag.

=head3 createVertex

 my $v = createVertex( $x, $y, $z );

Creates a B<Vertex> using the given C<$x, $y, $z> floating-point values
to represent the x, y, and z coordinates in 3D space.

=cut

sub createVertex {
    croak sprintf("!ERROR! createVertex(x,y,z): requires 3 coordinates; you supplied %d", scalar @_)
        unless 3==@_;
    return V(@_);
}

=head3 createFacet

 my $f = createFacet( $a, $b, $c );

Creates a B<Facet> using the three B<Vertex> arguments as the corner points of the triangle.

Note that the order of the B<Facet>'s vertices matters, and follows the
L<right-hand rule|https://en.wikipedia.org/wiki/Right-hand_rule> to determine the "outside" of
the B<Facet>: if you are looking at the B<Facet> such that the points are arranged in a
counter-clockwise order, then everything from the B<Facet> towards you (and behind you) is
"outside" the surface, and everything beyond the B<Facet> is "inside" the surface.

=cut

sub createFacet {
    croak sprintf("!ERROR! createFacet(t1,t2,t3): requires 3 Vertices; you supplied %d", scalar @_)
        unless 3==@_;
    foreach my $v ( @_ ) {
        croak sprintf("!ERROR! createFacet(t1,t2,t3): each Vertex must be an array ref or equivalent object; you supplied a scalar\"%s\"", $v//'<undef>')
            unless ref $v;

        croak sprintf("!ERROR! createFacet(t1,t2,t3): each Vertex must be an array ref or equivalent object; you supplied \"%s\"", ref $v)
            unless UNIVERSAL::isa($v,'ARRAY');  # use function notation, in case $v is not blessed

        croak sprintf("!ERROR! createFacet(t1,t2,t3): each Vertex requires 3 coordinates; you supplied %d: <%s>", scalar @$v, join(",", @$v))
            unless 3==@$v;
    }
    return [@_[0..2]];
}

=head4 createQuadrangleFacets

 my @f = createQuadrangleFacets( $a, $b, $c, $d );

Creates two B<Facet>s using the four B<Vertex> arguments as the corners of a quadrangle
(like with C<createFacet>, the arguments are ordered by the right-hand rule).  This returns
a list of two triangular B<Facet>s, for the triangles B<ABC> and B<ACD>.

=cut

sub createQuadrangleFacets {
    croak sprintf("!ERROR! createQuadrangleFacets(t1,t2,t3,t4): requires 4 Vertices; you supplied %d", scalar @_)
        unless 4==@_;
    my ($a,$b,$c,$d) = @_;
    return ( createFacet($a,$b,$c), createFacet($a,$c,$d) );
}

=head4 getx

=head4 gety

=head4 getz

 my $v = createVertex(1,2,3);
 my $x = getx($v); # 1
 my $y = getx($v); # 2
 my $z = getx($v); # 3

Grabs the individual x, y, or z coordinate from a vertex

=cut

sub getx($) { shift()->[XCOORD] }
sub gety($) { shift()->[YCOORD] }
sub getz($) { shift()->[ZCOORD] }

=head3 createMesh

 my $m = createMesh();          # empty
 my $s = createMesh($f, ...);   # pre-populated

Creates a B<Mesh>, optionally pre-populating the Mesh with the supplied B<Facet>s.

=cut

sub createMesh {
    foreach my $tri ( @_ ) {
        croak sprintf("!ERROR! createMesh(...): each triangle must be defined; this one was undef")
            unless defined $tri;

        croak sprintf("!ERROR! createMesh(...): each triangle requires 3 Vertices; you supplied %d: <%s>", scalar @$tri, join(",", @$tri))
            unless 3==@$tri;

        foreach my $v ( @$tri ) {
            croak sprintf("!ERROR! createMesh(...): each Vertex must be an array ref or equivalent object; you supplied a scalar\"%s\"", $v//'<undef>')
                unless ref $v;

            croak sprintf("!ERROR! createMesh(...): each Vertex must be an array ref or equivalent object; you supplied \"%s\"", ref $v)
                unless UNIVERSAL::isa($v, 'ARRAY');

            croak sprintf("!ERROR! createMesh(...): each Vertex in each triangle requires 3 coordinates; you supplied %d: <%s>", scalar @$v, join(",", @$v))
                unless 3==@$v;
        }
    }
    return [@_];
}

=head4 addToMesh

 addToMesh($mesh, $tri);
 addToMesh($mesh, $tri1, ... $triN);

=cut

sub addToMesh {
    my $mesh = shift;
    croak sprintf("!ERROR! addToMesh(\$mesh, \@triangles): mesh must have already been created")
        unless UNIVERSAL::isa($mesh, 'ARRAY');
    foreach my $tri ( @_ ) {
        croak sprintf("!ERROR! addToMesh(...): each triangle must be an array ref or equivalent object; you supplied a scalar \"%s\"", $tri//'<undef>')
            unless ref $tri;

        croak sprintf("!ERROR! addToMesh(...): each triangle must be an array ref or equivalent object; you supplied \"%s\"", ref $tri)
            unless UNIVERSAL::isa($tri, 'ARRAY');

        croak sprintf("!ERROR! addToMesh(...): each triangle requires 3 Vertices; you supplied %d: <%s>", scalar @$tri, join(",", @$tri))
            unless 3==@$tri;

        foreach my $v ( @$tri ) {
            croak sprintf("!ERROR! addToMesh(...): each Vertex must be an array ref or equivalent object; you supplied a scalar \"%s\"", $v//'<undef>')
                unless ref $v;

            croak sprintf("!ERROR! addToMesh(...): each Vertex must be an array ref or equivalent object; you supplied \"%s\"", ref $v)
                unless UNIVERSAL::isa($v, 'ARRAY');

            croak sprintf("!ERROR! addToMesh(...): each Vertex in each triangle requires 3 coordinates; you supplied %d: <%s>", scalar @$v, join(",", @$v))
                unless 3==@$v;
        }

        push @$mesh, $tri;
    }
    return $mesh;
}

################################################################
# math
################################################################

=head2 MATH FUNCTIONS

Three-dimensional math can take some special functions.  Some of those
are available to your script.

They can be imported into your script I<en masse> using the C<:math> tag.

=head3 unitDelta

 my $uAB = unitDelta( $A, $B );

Returns a vector (using same structure as a B<Vertex>), which gives the
direction from B<Vertex A> to B<Vertex B>.  This is scaled so that
the vector has a magnitude of 1.0.

=cut

sub unitDelta($$) {
    # TODO = argument checking
    my ($beg, $end) = @_;
    my $dx = $end->[XCOORD] - $beg->[XCOORD];
    my $dy = $end->[YCOORD] - $beg->[YCOORD];
    my $dz = $end->[ZCOORD] - $beg->[ZCOORD];
    my $m = sqrt( $dx*$dx + $dy*$dy + $dz*$dz );
    return $m ? [ $dx/$m, $dy/$m, $dz/$m ] : [0,0,0];
}

=head3 unitCross

 my $uN = unitCross( $uAB, $uBC );

Returns the cross product for the two vectors, which gives a vector
perpendicular to both.  This is scaled so that the vector has a
magnitude of 1.0.

A typical usage would be for finding the direction to the "outside"
(the normal-vector) using the right-hand rule.  For a B<Facet> with
points A, B, and C, first, find the direction from A to B, and from B
to C; the C<unitCross> of those two deltas gives you the normal-vector
(and, in fact, that's how S<C<facetNormal()>> is implemented).

 my $uAB = unitDelta( $A, $B );
 my $uBC = unitDelta( $B, $C );
 my $uN  = unitCross( $uAB, $uBC );

=cut

sub unitCross($$) {
    # TODO = argument checking
    my ($v1, $v2) = @_; # two vectors
    my $dx = $v1->[1]*$v2->[2] - $v1->[2]*$v2->[1];
    my $dy = $v1->[2]*$v2->[0] - $v1->[0]*$v2->[2];
    my $dz = $v1->[0]*$v2->[1] - $v1->[1]*$v2->[0];
    my $m = sqrt( $dx*$dx + $dy*$dy + $dz*$dz );
    return $m ? [ $dx/$m, $dy/$m, $dz/$m ] : [0,0,0];
}

=head3 facetNormal

 my $uN = facetNormal( $facet );

Uses S<C<unitDelta()>> and  S<C<unitCross()>> to find the normal-vector
for the given B<Facet>, given the right-hand rule order for the B<Facet>'s
vertices.

=cut

sub facetNormal($) {
    # TODO = argument checking
    my ($A,$B,$C) = @{ shift() };   # three vertices of the facet
    my $uAB = unitDelta( $A, $B );
    my $uBC = unitDelta( $B, $C );
    return    unitCross( $uAB, $uBC );
}

################################################################
# enabled formats
################################################################
our %EnabledFormats = ();

=head2 FORMATS

If you want to be able to output your mesh into a format, or input a mesh from a format, you need to enable them.
This makes it simple to incorporate an add-on C<CAD::Mesh3D::NiftyFormat>.

Note to developers: L<CAD::Mesh3D::ProvideNewFormat> documents how to write a submodule (usually in the C<CAD::Mesh3D>
namespace) to provide the appropriate input and/or output functions for a given format.  L<CAD::Mesh3D:STL> is a
format that ships with B<CAD::Mesh3D>, and provides an example of how to implement a format module.

The C<enableFormat>, C<output>, and C<input> functions can be imported using the C<:formats> tag.

=head3 enableFormat

 use CAD::Mesh3D qw/+STL :formats/;     # for the format 'STL'
  # or
 enableFormat( $format )
  # or
 enableFormat( $format => $moduleName  )

C<$moduleName> should be the name of the module that will provide the C<$format> routines.  It will default to 'CAD::Mesh3D::$format'.
The C<$format> is case-sensitive, so C<enableFormat( 'Stl' ); enableFormat( 'STL' );> will try to enable two separate formats.

=cut

#   Pass the name or coderef to these functions into L<enableFormat> to have the user's code exit with an appropriate error message if there is no appropriate input or output method for a given 3D format.
our $_input_function_not_avail  = sub { croak sprintf "Input function for %s is not available", defined $_[0] ? shift : 'your format' };
our $_output_function_not_avail = sub { croak sprintf "Output function for %s is not available", defined $_[0] ? shift : 'your format' };

sub enableFormat {
    my $formatName = defined $_[0] ? $_[0] : croak "!ERROR! enableFormat(...): requires name of format";
    my $formatModule = defined $_[1] ? $_[1] : "CAD::Mesh3D::$formatName";
    (my $key = $formatModule . '.pm') =~ s{::}{/}g;
    eval { require $key unless exists $INC{$key}; 1; } or do {
        local $" = ", ";
        croak "!ERROR! enableFormat( @_ ): \n\tcould not import $formatModule\n\t$@";
    };
    my %io = ();
    eval { %io = $formatModule->_io_functions(); 1; } or do {
        local $" = ", ";
        croak "!ERROR! enableFormat( @_ ): \n\t$formatModule doesn't seem to correctly provide the input and/or output functions\n\t";
    };
    $io{input}  = $_input_function_not_avail  unless defined $io{input};
    $io{output} = $_output_function_not_avail unless defined $io{output};
    # carp "STL input()  = $io{input}" if defined $io{input};
    # carp "STL output() = $io{output}" if defined $io{output};
    # see https://subversion.assembla.com/svn/pryrt/trunk/perl/perlmonks/mesh3d-unasked-question-20190215.pl for workaround using function

    $EnabledFormats{$formatName} = { %io, module => $formatModule };
}

################################################################
# file output
################################################################

=head3 output

Output the B<Mesh> to a 3D output file in the given format

 use CAD::Mesh3D qw/+STL :formats/;
 output($mesh, 'STL' => $file);
 output($mesh, 'STL' => $file, @args );

Outputs the given C<$mesh> to the indicated file.

The C<$file> argument is either an already-opened filehandle, or the name of the file
(if the full path is not specified, it will default to your script's directory),
or "STDOUT" or "STDERR" to direct the output to the standard handles.

You will need to look at the documentation for your selected format to see what additional
C<@args> it might want.  Often, the args will be used for setting format options, like
picking between ASCII and binary file formats, or similar.

=cut

sub output {
    my ($mesh, $format, @file_and_args) = @_;
    $EnabledFormats{$format}{output}->( $mesh, @file_and_args );
}

=head1 SEE ALSO

=over

=item * L<CAD::Format::STL> - includes both input and output from STL (ASCII and BINARY)

The unaddressed Windows bug was killer for me.  I possibly would have offered
to co-maintain and implement the bug fix, but I also wanted the possibility
of adding sub-modules to implment other input/output formats -- in which case, the naming
scheme is wrong.

=back

=head1 TODO

=over

=item * create C<input($mesh, 'STL' => ... )> ...

=item * allow object-oriented notation

=item * convert :output tag to :fileio tag

=back

=head1 AUTHOR

Peter C. Jones C<E<lt>petercj AT cpan DOT orgE<gt>>

=begin html

<a href="https://github.com/pryrt/CAD-Mesh3D/issues"><img src="https://img.shields.io/github/issues/pryrt/CAD-Mesh3D.svg" alt="issues" title="issues"></a>
<a href="https://ci.appveyor.com/project/pryrt/CAD-Mesh3D"><img src="https://ci.appveyor.com/api/projects/status/bc5jt6b2bjmpig5x?svg=true" alt="appveyor build status" title="appveyor build status"></a>
<a href="https://travis-ci.org/pryrt/CAD-Mesh3D"><img src="https://travis-ci.org/pryrt/CAD-Mesh3D.svg?branch=master" alt="travis build status" title="travis build status"></a>
<a href='https://coveralls.io/github/pryrt/CAD-Mesh3D?branch=master'><img src='https://coveralls.io/repos/github/pryrt/CAD-Mesh3D/badge.svg?branch=master' alt='Coverage Status' title='Coverage Status' /></a>

=end html

=head1 COPYRIGHT

Copyright (C) 2017,2018,2019 Peter C. Jones

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut

1;