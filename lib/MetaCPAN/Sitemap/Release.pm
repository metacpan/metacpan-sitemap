package MetaCPAN::Sitemap::Release;
use v5.36;

use Moo;

use namespace::clean;

with 'MetaCPAN::Sitemap';

has '+index' => (
  default => 'release',
);
has '+base_name' => (
  default => 'sitemap-releases',
);
has '+format' => (
  default => 'https://metacpan.org/dist/%{distribution}s',
);
has '+query' => (
  default => sub {
    {
      "query" => [
        "term" => { status => 'latest' },
      ],
      "_source" => [qw( distribution )],
    };
  },
);

1;
