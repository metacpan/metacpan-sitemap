package MetaCPAN::Sitemaps;
use v5.36;

use Moo;

use Plack::Builder qw(builder mount enable enable_if);
use Plack::App::File ();
use Plack::Request ();
use MetaCPAN::Config ();
use Search::Elasticsearch ();
use POSIX ();
use Plack::Util ();
use MetaCPAN::Logger qw(:log :dlog);
use Scalar::Util qw(blessed);
use Module::Runtime qw(require_module);
use Path::Tiny qw(tempdir path);
use Ref::Util qw(is_plain_hashref);

use namespace::clean;

has config => (
  is => 'ro',
);

around BUILDARGS => sub ($orig, $class, @args) {
  my $args = $class->$orig(@args);

  my $config = $args->{config} //= MetaCPAN::Config->from_lib;
  return {
    $config->config->%*,
    $args->%*,
  };
};

has es => (
  is => 'ro',
  required => 1,
  coerce => sub ($es_config) {
    return $es_config
      if blessed($es_config);
    Search::Elasticsearch->new($es_config);
  },
);

has base_dir => (
  is => 'lazy',
  default => sub {
    tempdir(
      TEMPLATE => 'metacpan-sitemap-XXXXXX',
      TMPDIR   => 1,
    );
  },
  coerce => sub ($dir) {
    ref $dir ? $dir : path($dir);
  },
);

has _maps => (
  is => 'ro',
  init_arg => 'maps',
);

has maps => (
  is => 'lazy',
  init_arg => undef,
  default => sub ($self) {
    my $config = $self->_maps;
    my $es = $self->es;
    my $base_dir = $self->base_dir;
    [ map {
      my %opts = %$_;
      my $class = delete $opts{class};
      require_module $class;
      $class->new(
        es => $es,
        base_dir => $base_dir,
        %opts,
      );
    } @$config ];
  },
);

sub regenerate ($self) {
  log_info { "Generating sitemaps" };
  for my $map ($self->maps->@*) {
    $map->generate;
  }
  return;
}

sub sitemap_app ($self, $map) {
  builder {
    enable 'Headers',
      append => ['Vary', 'Accept-Encoding'];
    enable_if sub ($env) {
      my $req = Plack::Request->new($env);
      my @encoding = map split(/,\s*/),
        $req->headers->header('Accept-Encoding');
      my $want_gzip = grep /\Agzip(?:;|\z)/, @encoding;
      return $want_gzip;
    }, sub {
      builder {
        enable 'Headers',
          append => ['Content-Encoding', 'gzip'];
        Plack::App::File->new(file => $map->gz, content_type => 'application/xml')->to_app;
      };
    };
    Plack::App::File->new(file => $map->file, content_type => 'application/xml')->to_app;
  };
}

sub to_app ($self) {
  $self->regenerate;

  my $rebuild_mw;
  if (my $rebuild = $self->config->config->{rebuild}) {
    require MetaCPAN::Middleware::Rebuild;
    $rebuild_mw = MetaCPAN::Middleware::Rebuild->new(
      lock_dir => $self->base_dir,
      is_plain_hashref($rebuild) ? $rebuild->%* : (),
      callback => sub { $self->regenerate },
    );
  }

  builder {
    enable 'XSendfile';
    for my $map ($self->maps->@*) {
      mount '/' . $map->base_name . '.xml' => builder {
        if ($rebuild_mw) {
          enable sub ($app) { $rebuild_mw->wrap($app) };
        }
        $self->sitemap_app($map);
      };
    }
    mount '/' => sub { [404, ['Content-Type' => 'text/plain'], ['Not found']] };
  };
}

1;
