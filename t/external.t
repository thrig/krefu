#!perl
#
# external interface tests (krefu called as a command)

use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use Test::Most;
use Test::UnixCmdWrap;

my $cmd      = Test::UnixCmdWrap->new(qw[cmd ./krefu]);
my $test_dir = tempdir('krefu.XXXXXXXXXX', CLEANUP => 1, TMPDIR => 1);

$ENV{KREFU_DIR} = $test_dir;
my $dbfile = catfile($test_dir, 'krefu.db');

ok !-e $dbfile
  or BAIL_OUT("krefu.db already exists?? $ENV{KREFU_DIR}");

$cmd->run(args => 'init');
ok -e $dbfile;

# repeated init should (in theory) not pose a problem
$cmd->run(args => 'init');

$cmd->run(args => 'decks');

my $deck = 'test' . $$;
$cmd->run(args => "add $deck 1 cipra test");

$cmd->run(args => 'decks', stdout => [$deck]);

$cmd->run(stderr => qr/Usage: /, status => 64);
$cmd->run(args   => 'nodasmuci', stderr => qr/unknown/, status => 64);

# TODO Expect.pm and train the one card

done_testing 23
