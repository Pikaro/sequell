package Henzell::Utils;
use base 'Exporter';

use strict;
use warnings;

use Fcntl qw/:flock/;

our @EXPORT_OK = qw/lock_or_die lock/;

sub lock_filename {
  my ($basename) = $main::0 =~ m{([^/]+)$};
  die "Could not discover program name in ($0) to acquire lock\n"
    unless $basename;
  my $dir = $ENV{HOME} || '.';
  "$dir/.$basename.lock"
}

sub lock_or_exit {
  my $exitcode = shift() || 0;
  my $lockf = lock_filename();
  open LOCKFILE, '>', $lockf or die "Couldn't open $lockf: $!\n";
  flock(LOCKFILE, LOCK_EX | LOCK_NB)
    or exit($exitcode);
}

sub lock {
  my %pars = @_;

  my $lockf = lock_filename();
  warn "Locking $lockf\n" if $pars{verbose};
  open LOCKFILE, '>', $lockf or die "Couldn't open $lockf: $!\n";
  flock(LOCKFILE, LOCK_EX) or die "Couldn't lock $lockf: $!\n";
  warn "Locked $lockf...\n" if $pars{verbose};
}

1