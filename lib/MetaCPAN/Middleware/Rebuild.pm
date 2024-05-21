package MetaCPAN::Middleware::Rebuild;
use v5.36;

use Moo;

use Fcntl qw(O_APPEND O_CREAT LOCK_EX LOCK_NB O_RDWR);
use Time::HiRes qw(time);
use Path::Tiny qw(tempdir);
use POSIX ();
use MetaCPAN::Logger qw(:log :dlog);
use Carp qw(croak);

use namespace::clean;

with 'MetaCPAN::Role::Middleware';

has lock_dir => (
  is => 'lazy',
  default => sub {
    tempdir(
      TEMPLATE => 'metacpan-sitemaps-lock-XXXXXX',
      TMPDIR => 1,
    );
  },
);

sub rebuild_lock ($self) {
  my $dir = $self->lock_dir . '/metacpan-rebuild.lock';
}

has period => (
  is => 'ro',
  default => 60*60*24,
  isa => sub {
    if ($_[0] < 0) {
      croak "period $_[0] is not a positive number!"
    }
  },
);

has variance => (
  is => 'ro',
  default => 0.001,
  isa => sub {
    if ($_[0] < 0 || $_[0] > 1) {
      croak "variance $_[0] is not between 0 and 1!";
    }
  },
);

sub rebuild_period ($self) {
  my $period = $self->period;
  if (my $variance = $self->variance) {
    my $var_range = $variance * $period;
    $period -= $var_range / 2 + rand($var_range);
  }
  $period;
}

has next_rebuild_time => (
  is => 'rwp',
  lazy => 1,
  default => sub ($self) { time + $self->rebuild_period },
);

sub BUILD ($self, @args) {
  $self->next_rebuild_time;
}

has callback => (
  is => 'ro',
  required => 1,
);

sub try_rebuild ($self) {
  my $lockfile = $self->rebuild_lock;

  # another process may have updated
  my $last_rebuild_time = (stat($lockfile))[9];
  if ($last_rebuild_time) {
    my $new_rebuild_time = $last_rebuild_time + $self->rebuild_period;

    my $now = time;
    if ($new_rebuild_time > $now) {
      log_debug { "lock file updated in other process " };
      $self->_set_next_rebuild_time($new_rebuild_time);
      return;
    }
  }

  if (sysopen my $fh, $lockfile, O_RDWR|O_CREAT) {
    if (flock $fh, LOCK_EX|LOCK_NB) {
      log_info { "Got rebuild lock" };
      my $pid = fork;
      if (!defined $pid) {
        die "fork failed!";
      }
      elsif ($pid) {
        waitpid $pid, 0;
        log_debug { "Cleaned up direct fork ($?)" };
      }
      else {
        fork and POSIX::_exit(0);
        $self->callback->();
        print { $fh } '1';
        truncate $fh, 0;
        close $fh;
        POSIX::_exit(0);
      }
    }
    else {
      log_debug { "Couldn't aquire lock" };
    }
  }
  else {
    log_error { "Error opening lock file: $!" };
  }

  return;
}

sub maybe_rebuild ($self) {
  if (time > $self->next_rebuild_time) {
    log_debug { "rebuild needed" };
    $self->try_rebuild;
  }
  else {
    log_debug { "rebuild not needed" };
  }
}

sub call ($self, $env) {
  $self->maybe_rebuild;
  $self->app->($env);
}

1;
