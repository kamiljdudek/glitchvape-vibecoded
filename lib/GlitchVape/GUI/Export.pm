package GlitchVape::GUI::Export;

use strict;
use warnings;

# Literal '·' and '…' appear in labels below. See the note at the top of
# GlitchVape::GUI for what happens without this.
use utf8;

use File::Basename qw(fileparse);

use Gtk3 ();

use GlitchVape::GUI::Profiles ();

use GlitchVape::Animate ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Export - what Export writes, and at what size

=head1 DESCRIPTION

Where a render goes is asked in a file chooser at the moment of exporting.
What it is -- format, size, frame rate, palette -- could be inferred from the
name typed there, letting the extension pick the encoder and the preset decide
the size. That is a fine default and a poor only option: the two things people
actually change are the size and the format, and neither should require
knowing that C<.webm> means VP9.

So they are settings instead, held in one place and edited in one dialog, with
a tab each for the two outputs. They are not the same question asked twice: a video
has a frame rate and a codec, a still has a palette, and the one thing they
share -- how big -- means different enough things in the two cases that it is
asked differently.

=head1 THE SETTINGS ARE A PLAIN HASH

C<run> is handed one and hands a new one back; nothing here holds state
between calls. That keeps this module a dialog rather than a second place
where the truth about an export lives, and it is what lets
L<GlitchVape::GUI::CommandLine> print the same settings without going through
a window.

=head2 Frame rate is one setting, shown twice

The frame rate is on the video tab and also in Animation settings, because it
is genuinely both: it is how fast the loop plays, which is a property of the
animation, and it is the rate of the file, which is a property of the export.
Rather than have two numbers that can disagree, both dialogs read and write
the same one -- and the video tab says so.

=head1 SIZES ARE A CAP ON THE LONG EDGE

The resolution list is the previewer's, extended upwards, and it means what
the previewer's means: a limit on the longer side, aspect preserved, never
enlarged. C<720> is 720x540 for a 4:3 photograph and 540x720 for a portrait
one. It is not the broadcast sense of 720p -- nothing here pads a picture out
to a frame it does not fill.

C<Native> is the exception, and is deliberately not the default: it means "do
not cap at all", and on a modern phone photograph that is a 12-megapixel
video, which is not what somebody who has not thought about it wants.

=cut

# Longest edge, and the label for it. The first three are the previewer's own
# list so that a preview and an export at the same setting mean the same
# thing; the rest are there because an export is where the large sizes are
# actually wanted.
my @SIZES = (
    [ 512,  'Small · 512 px' ],
    [ 720,  'Standard · 720 px' ],
    [ 900,  'Detailed · 900 px' ],
    [ 1080, 'Large · 1080 px' ],
    [ 1440, 'Very large · 1440 px' ],
    [ 1920, 'Full HD · 1920 px' ],
    [ 0,    'Native — no limit' ],
);

# key => container extension, codec for GlitchVape::Animate, and what to call
# it. Keyed rather than positional because the key is what gets stored, and a
# stored index would silently mean something else the day a format is added.
my @VIDEO_FORMATS = (
    {
        key   => 'mp4',
        ext   => 'mp4',
        codec => 'h264',
        label => 'MP4 · H.264',
        note  => 'Common default.',
    },
    {
        key   => 'webm',
        ext   => 'webm',
        codec => 'vp9',
        label => 'WebM · VP9',
        note  => 'Smaller than MP4 at the same quality; plays in browsers.',
    },
    {
        key   => 'webm-av1',
        ext   => 'webm',
        codec => 'av1',
        label => 'WebM · AV1',
        note  => 'Smallest of the three, modern and demanding codec.',
    },
);

my @STILL_FORMATS = (
    {
        key   => 'origin',
        label => 'Same as the original',
        note  => 'A JPEG in stays a JPEG out; a HEIC stays a HEIC.',
    },
    {
        key   => 'png',
        ext   => 'png',
        label => 'PNG',
        note  => 'Lossless and popular',
    },
    {
        key    => 'bmp256',
        ext    => 'bmp',
        colors => 256,
        label  => 'Windows Bitmap · 256 colours',
        note   => 'An 8-bit .bmp with a dithered palette, as a 1995 '
            . 'desktop would have held it.',
    },
);

# The retro box, in the orientation of a landscape picture. It turns with the
# photograph -- see GlitchVape::IO -- so a portrait shot gets 480x640 rather
# than 360x480, which is what a screen of this size actually did with one.
use constant RETRO_BOX => [ 640, 480 ];

=head2 defaults()

The settings a fresh session starts with.

=cut

sub defaults { return GlitchVape::GUI::Profiles::defaults() }

=head2 run( %arg )

    parent   => Gtk3::Window
    settings => the current hash
    on_done  => sub { my ( $settings ) = @_ }

Modal. C<on_done> is called with a new hash when the dialog is closed, and not
at all if it is cancelled.

=cut

sub manage
{
    my ( $class, %arg ) = @_;

    my $profiles = GlitchVape::GUI::Profiles::load();

    my $dialog = Gtk3::Dialog->new_with_buttons(
        'Export profiles',
        $arg{ parent },
        'modal', 'Close', 'close'
    );
    $dialog->set_default_size( 520, 420 );

    my $book = Gtk3::Notebook->new;
    $book->set_border_width( 10 );

    my %pane;
    for my $kind ( [ video => 'Videos' ], [ still => 'Stills' ] )
    {
        my ( $key, $label ) = @$kind;

        $pane{ $key } = _profile_pane( $dialog, $profiles, $key );
        $book->append_page( $pane{ $key }{ page }, Gtk3::Label->new( $label ) );
    }

    # One list changing can add a name the other has to avoid, so both are
    # rebuilt from the one array whenever either of them edits it.
    my $refresh = sub {
        $_->{ rebuild }->() for values %pane;
        GlitchVape::GUI::Profiles::save( $profiles );
        return;
    };
    $_->{ on_change }->( $refresh ) for values %pane;

    $dialog->get_content_area->add( $book );
    $dialog->show_all;
    $dialog->run;
    $dialog->destroy;

    $arg{ on_done }->( $profiles ) if $arg{ on_done };

    return $profiles;
}

# One tab: the profiles of one kind, and the four things that can be done to
# one. A list with an action bar under it rather than a row of buttons beside
# each entry -- the actions are about whichever is selected, and repeating
# them per row says the opposite.
sub _profile_pane
{
    my ( $parent, $profiles, $kind ) = @_;

    my $page = Gtk3::Box->new( 'vertical', 0 );

    my $list = Gtk3::ListBox->new;
    $list->set_activate_on_single_click( 0 );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_vexpand( 1 );
    $scroll->add( $list );
    $page->pack_start( $scroll, 1, 1, 0 );

    my $bar = Gtk3::ActionBar->new;
    $page->pack_start( $bar, 0, 0, 0 );

    my %state  = ( rows => [] );
    my $notify = sub { };

    my $selected = sub {
        my $row = $list->get_selected_row or return undef;
        return $state{ rows }[ $row->get_index ];
    };

    my $rebuild = sub {
        $_->destroy for $list->get_children;
        @{ $state{ rows } } = ();

        for my $one (
            @{ GlitchVape::GUI::Profiles::of_kind( $profiles, $kind ) } )
        {
            push @{ $state{ rows } }, $one;
            $list->add( _profile_row( $one, $kind ) );
        }

        $list->show_all;
        return;
    };

    # A shipped profile is read-only, the same as it is unremovable, though for
    # a better reason than symmetry. Removing one cannot work at all: it comes
    # back on the next load. Editing one *did* work -- it turned the row into
    # the user's own copy, which then overrode the shipped one by name -- and
    # the way back was to notice that Remove had become available and that
    # using it restored the original, which nothing said anywhere.
    #
    # A default that can be permanently changed by a route back nobody can
    # find is worse than one that cannot be changed at all. Duplicate is how
    # you get a profile like this one but different, and the greyed Edit says
    # so rather than merely refusing.
    my $edit = sub {
        my ( $one ) = @_;
        return unless $one && !$one->{ builtin };

        my $edited = _edit_profile( $parent, $profiles, $one );
        return unless $edited;

        $one->{ $_ } = $edited->{ $_ } for keys %$edited;

        $notify->();
        return;
    };

    for my $action (
        [
            'Add',
            'list-add-symbolic',
            sub {
                my $one = {
                    name => GlitchVape::GUI::Profiles::unique_name(
                        $profiles, ucfirst( $kind ) . ' profile'
                    ),
                    kind     => $kind,
                    builtin  => 0,
                    settings => {},
                };

                my $edited = _edit_profile( $parent, $profiles, $one );
                return unless $edited;

                push @$profiles, { %$edited, builtin => 0 };
                $notify->();
                return;
            }
        ],
        [
            'Duplicate',
            'edit-copy-symbolic',
            sub {
                my $one = $selected->() or return;

                push @$profiles,
                    {
                    name => GlitchVape::GUI::Profiles::unique_name(
                        $profiles, $one->{ name }
                    ),
                    kind     => $one->{ kind },
                    builtin  => 0,
                    settings => { %{ $one->{ settings } } },
                    };

                $notify->();
                return;
            }
        ],
        [
            'Edit',
            'document-edit-symbolic',
            sub { $edit->( $selected->() ); return }
        ],
        [
            'Remove',
            'user-trash-symbolic',
            sub {
                my $one = $selected->() or return;

                # A built-in cannot be removed, only reset: it would come
                # straight back on the next load, which would read as the
                # button not working.
                @$profiles = grep { $_ != $one } @$profiles;

                $notify->();
                return;
            }
        ],
        )
    {
        my ( $label, $icon, $action_sub ) = @$action;

        my $button = Gtk3::Button->new;
        $button->set_image(
            Gtk3::Image->new_from_icon_name( $icon, 'button' ) );
        $button->signal_connect( clicked => $action_sub );

        # Wrapped so the tooltip survives the button being greyed out. An
        # insensitive widget stops taking pointer events and a tooltip is shown
        # from the pointer being over something, so a tooltip on the button
        # itself is the one nobody can read -- exactly the tooltip that has
        # something to explain. The box around it stays sensitive and carries
        # the words instead. set_visible_window(0) keeps it from drawing a
        # background of its own over the bar.
        my $around = Gtk3::EventBox->new;
        $around->set_visible_window( 0 );
        $around->add( $button );

        $bar->pack_start( $around );

        $state{ button }{ $label } = $button;
        $state{ around }{ $label } = $around;
    }

    # Icons alone, so the words have to live somewhere. Each button says what
    # it does, and when it cannot, says why not.
    my $explain = sub {
        my ( $label, $on, $why ) = @_;

        $state{ button }{ $label }->set_sensitive( $on ? 1 : 0 );
        $state{ around }{ $label }->set_tooltip_text( $why );

        return;
    };

    my $sync = sub {
        my $one = $selected->();

        for my $action ( qw(Add Duplicate Edit Remove) )
        {
            my ( $on, $why ) = _availability( $action, $one );
            $explain->( $action, $on, $why );
        }

        return;
    };

    $list->signal_connect( 'row-selected' => $sync );
    $list->signal_connect(
        'row-activated' => sub { $edit->( $selected->() ) } );

    $rebuild->();
    $sync->();

    return {
        page      => $page,
        rebuild   => sub { $rebuild->(); $sync->(); return },
        on_change => sub { $notify = $_[ 0 ]; return },
    };
}

# Whether an action applies to the selected profile, and the sentence saying
# why when it does not.
#
# Every one of these buttons is an icon, so the tooltip is the only place any
# of it is written down -- and a greyed button with nothing to say is
# indistinguishable from a broken one. The two reasons a thing can be
# unavailable are kept apart: nothing selected is a different fact from this
# one being a default, and sharing a vague sentence would answer neither.
sub _availability
{
    my ( $action, $one ) = @_;

    return ( 1, 'Add a profile' ) if $action eq 'Add';

    return ( 0, "Select a profile to \L$action" ) unless $one;

    my $name    = $one->{ name };
    my $builtin = $one->{ builtin };

    return ( 1,
        $builtin
        ? "Copy '$name' to a profile you can edit"
        : "Duplicate '$name'" )
        if $action eq 'Duplicate';

    return ( !$builtin,
        $builtin
        ? 'A default profile cannot be edited. Duplicate it and edit the copy'
        : "Edit '$name'" )
        if $action eq 'Edit';

    return ( !$builtin, $builtin
        ? 'You cannot remove a default profile'
        : "Remove '$name'" );
}

sub _profile_row
{
    my ( $one, $kind ) = @_;

    my $row = Gtk3::ListBoxRow->new;

    my $box = Gtk3::Box->new( 'vertical', 2 );
    $box->set_border_width( 8 );

    my $name = Gtk3::Label->new( $one->{ name } );
    $name->set_xalign( 0 );
    $box->pack_start( $name, 0, 0, 0 );

    my $said = Gtk3::Label->new(
        describe(
            GlitchVape::GUI::Profiles::settings( $one ),
            $kind eq 'video'
        )
    );
    $said->set_xalign( 0 );
    $said->get_style_context->add_class( 'dim-label' );
    $box->pack_start( $said, 0, 0, 0 );

    $row->add( $box );

    return $row;
}

# One profile, in a dialog: its name, and the page for its kind. Returns the
# edited copy, or nothing if it was cancelled.
sub _edit_profile
{
    my ( $parent, $profiles, $one ) = @_;

    my %settings = %{ GlitchVape::GUI::Profiles::settings( $one ) };

    my $dialog = Gtk3::Dialog->new_with_buttons( 'Edit export profile',
        $parent, 'modal', 'Cancel', 'cancel', 'Save', 'accept' );
    $dialog->set_default_size( 460, -1 );

    my $box = Gtk3::Box->new( 'vertical', 10 );
    $box->set_border_width( 10 );

    my $name = Gtk3::Entry->new;
    $name->set_text( $one->{ name } );
    $name->set_activates_default( 1 );

    my $named = Gtk3::Box->new( 'horizontal', 10 );
    $named->pack_start( Gtk3::Label->new( 'Name' ), 0, 0, 0 );
    $named->pack_start( $name,                      1, 1, 0 );
    $box->pack_start( $named, 0, 0, 0 );

    my $body =
        $one->{ kind } eq 'video'
        ? _video_page( \%settings )
        : _still_page( \%settings );

    $box->pack_start( $body->{ page }, 1, 1, 0 );

    $dialog->get_content_area->add( $box );
    $dialog->set_default_response( 'accept' );
    $dialog->show_all;

    my $answer = $dialog->run;
    my %read   = ( %settings, %{ $body->{ read }->() } );
    my $typed  = $name->get_text;

    $dialog->destroy;

    return undef unless $answer eq 'accept';

    # A profile stores only what its kind uses. Keeping the rest would write
    # a frame rate into a PNG profile, where the next reader would reasonably
    # wonder what it meant.
    my @keep =
        $one->{ kind } eq 'video'
        ? qw(video_size video_format fps frames)
        : qw(still_format retro);

    my %kept = map { exists $read{ $_ } ? ( $_ => $read{ $_ } ) : () } @keep;

    # Renaming onto another profile's name would make the saved file
    # ambiguous about which one it is.
    my $final = $typed;
    $final = $one->{ name } unless length $final;
    $final = GlitchVape::GUI::Profiles::unique_name( $profiles, $final )
        if $final ne $one->{ name };

    return { name => $final, kind => $one->{ kind }, settings => \%kept };
}

# ---------------------------------------------------------------------------
# Pages

sub _video_page
{
    my ( $settings ) = @_;

    my $grid = _grid();
    my $row  = 0;

    my $fps = Gtk3::SpinButton->new_with_range( 1, 60, 1 );
    $fps->set_value( $settings->{ fps } );
    $fps->set_tooltip_text( 'How fast the loop plays. The same setting as '
            . 'the frame rate in Animation settings' );

    my $size = _size_combo( $settings->{ video_size } );
    $size->set_tooltip_text(
        'A limit on the longer side. The aspect ratio is never changed and '
            . 'a smaller picture is never enlarged' );

    my $format = Gtk3::ComboBoxText->new;
    $format->append_text( _format_label( $_ ) ) for @VIDEO_FORMATS;
    $format->set_active(
        _index_of( \@VIDEO_FORMATS, $settings->{ video_format } ) );

    my $note = _note_label();

    my $describe = sub {
        my $chosen = $VIDEO_FORMATS[ $format->get_active ] or return;
        my $text   = $chosen->{ note };

        # Said at the moment of choosing rather than at the end of a long
        # encode that fails: an ffmpeg without libsvtav1 is an ordinary
        # Fedora install, not a broken one.
        $text .=
              "\nThis ffmpeg cannot write it — install an ffmpeg with "
            . 'the AV1 encoder, or choose another format.'
            unless GlitchVape::Animate::codec_available( $chosen->{ codec } );

        $note->set_text( $text );
        return;
    };

    $format->signal_connect( changed => sub { $describe->(); return } );
    $describe->();

    $row = _pair( $grid, $row, 'Frame rate', $fps );
    $row = _pair( $grid, $row, 'Resolution', $size );
    $row = _pair( $grid, $row, 'Format',     $format );

    $grid->attach( $note, 0, $row++, 2, 1 );

    return {
        page => $grid,
        read => sub {
            return {
                fps          => int $fps->get_value,
                video_size   => $SIZES[ $size->get_active ][ 0 ],
                video_format => $VIDEO_FORMATS[ $format->get_active ]{ key },
            };
        },
    };
}

sub _still_page
{
    my ( $settings ) = @_;

    my $grid = _grid();
    my $row  = 0;

    my $format = Gtk3::ComboBoxText->new;
    $format->append_text( _format_label( $_ ) ) for @STILL_FORMATS;
    $format->set_active(
        _index_of( \@STILL_FORMATS, $settings->{ still_format } ) );

    my $note = _note_label();

    $format->signal_connect(
        changed => sub {
            my $chosen = $STILL_FORMATS[ $format->get_active ] or return;
            $note->set_text( $chosen->{ note } );
            return;
        }
    );
    $note->set_text( $STILL_FORMATS[ $format->get_active ]{ note } );

    my ( $bw, $bh ) = @{ +RETRO_BOX };

    my $retro = Gtk3::CheckButton->new_with_label(
        "Keep retro-friendly dimensions (${bw}×${bh})" );
    $retro->set_active( $settings->{ retro } ? 1 : 0 );
    $retro->set_tooltip_text(
              "Shrink the exported picture until it fits a ${bw}×${bh} "
            . "screen, keeping its proportions.\n"
            . 'The box turns with the photograph, so a portrait shot '
            . "becomes ${bh}×${bw} rather than being made tiny" );

    $row = _pair( $grid, $row, 'Format', $format );

    $grid->attach( $note,  0, $row++, 2, 1 );
    $grid->attach( $retro, 0, $row++, 2, 1 );

    my $why = _note_label();
    $why->set_text( 'Applied to the finished picture, so a border or a '
            . 'letterbox added by an effect is inside the box rather than '
            . 'pushing the result out of it.' );
    $grid->attach( $why, 0, $row++, 2, 1 );

    return {
        page => $grid,
        read => sub {
            return {
                still_format => $STILL_FORMATS[ $format->get_active ]{ key },
                retro        => $retro->get_active ? 1 : 0,
            };
        },
    };
}

# ---------------------------------------------------------------------------
# What the settings mean to a render

=head2 video_target( $settings )

C<< ( ext => 'webm', codec => 'av1' ) >> for the chosen video format.

=cut

sub video_target
{
    my ( $settings ) = @_;

    my $chosen = _entry( \@VIDEO_FORMATS, $settings->{ video_format } );

    return ( ext => $chosen->{ ext }, codec => $chosen->{ codec } );
}

=head2 still_extension( $settings, $source )

The extension a still should be written with. C<origin> resolves against the
file that was opened, falling back to PNG for a source whose extension is not
one anything can write back -- a HEIC on a machine without an HEVC encoder is
the ordinary case, and L<GlitchVape::IO> would have to route around it.

=cut

sub still_extension
{
    my ( $settings, $source ) = @_;

    my $chosen = _entry( \@STILL_FORMATS, $settings->{ still_format } );

    return $chosen->{ ext } if $chosen->{ ext };

    my ( undef, undef, $ext ) = fileparse( lc( $source // q{} ), qr/[.][^.]*/ );
    $ext =~ s/^[.]//;

    return 'png' unless length $ext;
    return $ext;
}

=head2 render_options( $settings, $animated )

The arguments L<GlitchVape/render> needs to honour these settings, as a list
suitable for splicing into its call. Which ones apply depends on what is being
written, so the caller says which it is.

=cut

sub render_options
{
    my ( $settings, $animated ) = @_;

    if ( $animated )
    {
        my %target = video_target( $settings );

        # A size of 0 is Native, which is the absence of a cap rather than a
        # cap of zero -- so it is left out entirely and the preset's own
        # max_dim stands.
        my @argv = ( codec => $target{ codec } );
        push @argv, max_dim => $settings->{ video_size }
            if $settings->{ video_size };

        return @argv;
    }

    my $chosen = _entry( \@STILL_FORMATS, $settings->{ still_format } );

    my @argv;
    push @argv, colors => $chosen->{ colors } if $chosen->{ colors };
    push @argv, fit    => RETRO_BOX           if $settings->{ retro };

    return @argv;
}

=head2 describe( $settings, $animated )

One line for the status bar.

=cut

sub describe
{
    my ( $settings, $animated ) = @_;

    if ( $animated )
    {
        my $chosen = _entry( \@VIDEO_FORMATS, $settings->{ video_format } );

        return sprintf '%s · %s · %d fps', $chosen->{ label },
            _size_label( $settings->{ video_size } ), $settings->{ fps };
    }

    my $chosen = _entry( \@STILL_FORMATS, $settings->{ still_format } );
    my $said   = $chosen->{ label };

    $said .= sprintf ' · fits %d×%d', @{ +RETRO_BOX } if $settings->{ retro };

    return $said;
}

=head2 retro_box()

The box C<retro> fits into, as C<< [ W, H ] >>.

=cut

sub retro_box { return RETRO_BOX }

=head2 sizes()

The resolution list, as C<< [ [ px, label ], ... ] >>. Exported for the tests
and for anything that needs to know what is on offer without building a combo.

=cut

sub sizes
{
    return [ map { [ @$_ ] } @SIZES ];
}

=head2 video_formats()

=head2 still_formats()

The format tables, as copies. Exposed for the same reason C<sizes> is: the
wizard lays the same choices out its own way, and a second copy of the list
would be a second thing to update when a format is added.

=cut

sub video_formats { return _copies( \@VIDEO_FORMATS ) }
sub still_formats { return _copies( \@STILL_FORMATS ) }

# Fresh hashes, not the module's own: a caller building a page from these is
# entitled to annotate them without editing the format table underneath.
sub _copies
{
    my ( $list ) = @_;

    my @out;
    push @out, { %$_ } for @$list;

    return \@out;
}

=head2 format_note( $settings, $animated )

What the chosen format is good for, in one line, or empty if it says nothing.

=cut

sub format_note
{
    my ( $settings, $animated ) = @_;

    my $list = $animated ? \@VIDEO_FORMATS : \@STILL_FORMATS;
    my $key =
        $animated ? $settings->{ video_format } : $settings->{ still_format };

    return _entry( $list, $key )->{ note } // q{};
}

# ---------------------------------------------------------------------------

sub _entry
{
    my ( $list, $key ) = @_;

    for my $entry ( @$list )
    {
        return $entry if $entry->{ key } eq ( $key // q{} );
    }

    # A settings hash from somewhere unexpected should not take the export
    # down; the first entry is the default in every one of these lists.
    return $list->[ 0 ];
}

sub _index_of
{
    my ( $list, $key ) = @_;

    for my $n ( 0 .. $#$list )
    {
        return $n if $list->[ $n ]{ key } eq ( $key // q{} );
    }

    return 0;
}

sub _format_label { return $_[ 0 ]{ label } }

sub _size_label
{
    my ( $px ) = @_;

    for my $entry ( @SIZES )
    {
        return $entry->[ 1 ] if $entry->[ 0 ] == ( $px // 0 );
    }

    return "$px px";
}

sub _size_combo
{
    my ( $current ) = @_;

    my $combo = Gtk3::ComboBoxText->new;
    my $index = 0;

    for my $n ( 0 .. $#SIZES )
    {
        $combo->append_text( $SIZES[ $n ][ 1 ] );
        $index = $n if $SIZES[ $n ][ 0 ] == ( $current // 0 );
    }

    $combo->set_active( $index );

    return $combo;
}

sub _grid
{
    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 8 );
    $grid->set_column_spacing( 10 );
    $grid->set_border_width( 14 );

    return $grid;
}

sub _pair
{
    my ( $grid, $row, $text, $control ) = @_;

    my $label = Gtk3::Label->new( $text );
    $label->set_xalign( 0 );

    $control->set_hexpand( 1 );

    $grid->attach( $label,   0, $row, 1, 1 );
    $grid->attach( $control, 1, $row, 1, 1 );

    return $row + 1;
}

sub _note_label
{
    my $label = Gtk3::Label->new;
    $label->set_xalign( 0 );
    $label->set_line_wrap( 1 );
    $label->set_max_width_chars( 46 );
    $label->get_style_context->add_class( 'dim-label' );

    return $label;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Animate> for the codecs, L<GlitchVape::IO> for what C<fit> and
C<colors> do to a file, and L<GlitchVape::GUI> for the menu that opens this.

=cut
