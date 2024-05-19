package MetaCPAN::Sitemaps;
use v5.36;

use Moo;

use Plack::Builder qw(builder mount enable enable_if);
use Plack::App::File ();
use Plack::Request ();
use MetaCPAN::Sitemap::Author ();
use MetaCPAN::Sitemap::Release ();
use MetaCPAN::Config ();
use Search::Elasticsearch ();
use POSIX ();
use Plack::Util ();
use MetaCPAN::Logger qw(:log :dlog);
use Scalar::Util qw(blessed);
use Module::Runtime qw(require_module);
use Path::Tiny qw(tempdir path);

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
    [ map {
      my %opts = %$_;
      my $class = delete $opts{class};
      require_module $class;
      $class->new(
        es => $es,
        %opts,
      );
    } @$config ];
  },
);

sub to_app ($self) {
  for my $map ($self->maps->@*) {
    $map->generate;
  }
  # $self->_set_rebuild_time(time);

  builder {
    enable 'XSendfile';
    #enable sub ($app) {
    #  sub ($env) {
    #    if ($self->
    #    $app->($env);
    #  };
    #};
    for my $map ($self->maps->@*) {
      mount '/' . $map->base_name . '.xml' => builder {
        enable 'Headers',
          append => ['Vary', 'Accept-Encoding'];
        enable_if sub ($env) {
          my $req = Plack::Request->new($env);
          my $want_gzip =
            grep /\Agzip(?:;|\z)/,
            map split(/,\s*/),
            $req->headers->header('Accept-Encoding');
          $want_gzip;
        }, sub {
          builder {
            enable 'Headers',
              append => ['Content-Encoding', 'gzip'];
            Plack::App::File->new(file => $map->gz, content_type => 'application/xml')->to_app;
          }
        };
        Plack::App::File->new(file => $map->file, content_type => 'application/xml')->to_app;
      };
    }
    mount '/' => sub {  };
  };
}

has rebuild_period => (
  is => 'ro',
  default => 60*60*24,
);

has rebuild_time => (
  is => 'rwp',
);

1;
