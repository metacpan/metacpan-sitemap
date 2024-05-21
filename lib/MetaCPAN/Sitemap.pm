package MetaCPAN::Sitemap;
use v5.36;

use Moo::Role;

use Path::Tiny qw(path tempdir);
use String::Formatter named_stringf => {
  codes => {
    s => sub { $_ },
  },
};
use MetaCPAN::Logger qw(:log :dlog);

use HTML::Entities     qw( encode_entities_numeric );
use IO::Compress::Gzip qw(gzip Z_BEST_COMPRESSION);

use namespace::clean;

has es => (
  is       => 'ro',
  required => 1,
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

has file => (
  is => 'rwp',
);

has gz => (
  is => 'rwp',
);

has index => (
  is => 'ro',
  required => 1,
);
has type => (
  is => 'ro',
);

has base_name => (
  is => 'ro',
  required => 1,
);
has query => (
  is => 'ro',
  required => 1,
);
has format => (
  is => 'ro',
  required => 1,
);

sub get_iterator ($self) {
  my $scroll = $self->es->scroll_helper(
    search_type => 'scan',
    size        => 500,
    scroll_in_qs => 1,
    index       => $self->index,
    ( defined $self->type ? ( type => $self->type ) : ()),
    body        => $self->query,
  );

  sub {
    my $next = $scroll->next or return undef;
    return $next->{_source};
  };
}

sub url_fields ($self, $attr) {
  return {
    loc => named_stringf($self->format, $attr),
  };
}

sub gen_sitemap ($self) {
  my $base_name = $self->base_name;
  log_info { "Generating $base_name sitemap" };
  my $tempfile = File::Temp->new(
    TEMPLATE  => $base_name.'-XXXXXX',
    DIR       => $self->base_dir->stringify,
    SUFFIX    => '.xml',
    UNLINK    => 0,
  );
  my $path = path("$tempfile");

  $tempfile->print(<<'END_XML_HEADER');
<?xml version='1.0' encoding='UTF-8'?>
<urlset xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
        xsi:schemaLocation="http://www.sitemaps.org/schemas/sitemap/0.9 http://www.sitemaps.org/schemas/sitemap/0.9/sitemap.xsd">
END_XML_HEADER

  my $iter = $self->get_iterator;
  my $records = 0;
  while (my $item = $iter->()) {
    $records++;
    my $fields = $self->url_fields($item);
    my $out = '<url>';
    for my $field (sort keys %$fields) {
      $out .= "<$field>" . encode_entities_numeric($fields->{$field}) . "</$field>";
    }
    $out .= "</url>\n";
    $tempfile->print($out);
  }

  $tempfile->print("</urlset>\n");
  $tempfile->close;

  log_info { "Created " . $path->basename . " with $records records" };

  return $path;
}

sub gen_sitemap_gz ($self, $file = $self->file) {
  my $base_name = $self->base_name;

  my $tempfile = File::Temp->new(
    TEMPLATE  => $base_name.'-XXXXXX',
    DIR       => $self->base_dir->stringify,
    SUFFIX    => '.xml.gz',
    UNLINK    => 0,
  );
  my $path = path("$tempfile");

  log_info { "Compressing " . $file->basename . " to " . $path->basename };

  gzip("$file", $tempfile,
    -Level => Z_BEST_COMPRESSION,
  );
  $tempfile->close;

  return Path::Tiny->new("$tempfile");
}

sub generate ($self) {
  my $map = $self->gen_sitemap;
  my $gz = $self->gen_sitemap_gz($map);
  my $final = $self->base_dir->child($self->base_name . '.xml');
  my $final_gz = $self->base_dir->child($self->base_name . '.xml.gz');
  log_info { "Moving " . $map->basename . " to " . $final->basename };
  $map->move($final);
  log_info { "Moving " . $gz->basename . " to " . $final_gz->basename };
  $gz->move($final_gz);
  $self->_set_file($final);
  $self->_set_gz($final_gz);
  return 1;
}

1;
