#!perl

use 5.26.0;
use warnings;
use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use Test::Most;
use Test::UnixCmdWrap;

my $cmd      = Test::UnixCmdWrap->new;
my $test_dir = tempdir('krefu.XXXXXXXXXX', CLEANUP => 1, TMPDIR => 1);
#diag 'export KREFU_DIR=' . $test_dir;

ok $test_dir !~ m/\s/ or BAIL_OUT("whitespace found in test path '$test_dir'");

$ENV{KREFU_DIR} = $test_dir;

my $dbfile = catfile($test_dir, 'krefu.db');

# krefu.tcl overrides code in krefu
my $override = catfile($test_dir, 'krefu.tcl');
my $ofh;

ok !-e $dbfile
  or BAIL_OUT("krefu.db already exists?? $ENV{KREFU_DIR}");

ok !-e $override
  or BAIL_OUT("krefu.tcl already exists?? $ENV{KREFU_DIR}");

# init
{
    $cmd->run(args => 'init');
    ok -e $dbfile;

    # repeated init should (in theory) not pose a problem
    $cmd->run(args => 'init');
}

# no decks, deck with one card in it
my $deck  = 'jbo' . $$;
my $front = 'cipra' . $$;
my $back  = 'test' . $$;
{
    $cmd->run(args => 'decks');
    $cmd->run(args => "add $deck 1 $front $back");
    $cmd->run(args => 'decks', stdout => [$deck]);
}

{
    open $ofh, '>', $override or BAIL_OUT("failed to write $override: $!");
    # invalid TCL
    $ofh->say("set broken$$");
    to_disk($ofh);

    $cmd->run(args => 'decks', status => 1, stderr => qr/broken$$/);

    seek $ofh, 0, 0;
    truncate $ofh, 0;
    to_disk($ofh);

    # one reason might be is the changes aren't sync'ing quick enough
    # (or at all) to the disk, maybe add sleep statements to better
    # ensure that?
    $cmd->run(args => 'decks', stdout => [$deck])
      or BAIL_OUT("krefu.tcl still broken??");
}

# quit
$cmd->run(
    args   => "train $deck",
    stdin  => 'Q',
    stdout => qr/Question:.*$front/
);

# show answer and then quit
$cmd->run(
    args   => "train $deck",
    stdin  => ' Q',
    stdout => qr/(?s)Question:.*$front.*Answer:.*$back/
);

# ignore the card
$cmd->run(
    args   => "train $deck",
    stdin  => 'I',
    stdout => qr/Question:.*$front/,
    stderr => qr/no cards remain/
);

# should be nothing left to train on
$cmd->run(
    args   => "train $deck",
    stdout => qr/^/,
    stderr => qr/no cards remain/
);

# TODO modify krefu.tcl and change mediacmd to something that can be
# tested. will also need a card with media set

# custom media commands
{
    $ofh->say(
        qq{set mediacmd [dict create audio "./t/touch a" image "./t/touch i"]});
    to_disk($ofh);

    # NOTE [file normalize $path] is done on the path component of media
    # specifications: relative paths will be fully qualified (and also ~
    # expanded out to user home dirs)
    $cmd->run(args => 'add media 0 ftxt btxt '
          . "'audio:$test_dir/fau1 audio:$test_dir/fau2 image:$test_dir/fim' "
          . "'image:$test_dir/bim'");

    $cmd->run(
        args   => "train media",
        stdin  => ' Q',
        stdout => qr/(?s)Question:.*ftxt.*Answer:.*btxt/
    );

    # KLUGE media commands are run in the background so may take some
    # time to complete especially if the system is busy
    diag "waiting for media commands to hopefully exit...";
    sleep 5;
    for my $f (qw[fau1 fau2 fim bim]) {
        ok -f catfile($test_dir, $f), "exists? $f";
    }
}

# invalid stuff
$cmd->run(stderr => qr/Usage: /, status => 64);
$cmd->run(args   => 'nodasmuci', stderr => qr/unknown/, status => 64);

# or try to, anyways
sub to_disk {
    $_[0]->flush;
    eval { $_[0]->sync };
}

done_testing 53
