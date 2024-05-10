package MetaCPAN::Sitemap::Author;
use v5.36;

use Moo;

use namespace::clean;

with 'MetaCPAN::Sitemap';

has '+index' => (
  default => 'author',
);
has '+base_name' => (
  default => 'sitemap-authors',
);
has '+format' => (
  default => 'https://metacpan.org/author/%{pauseid}s',
);
has '+query' => (
  default => sub {
    {
      "_source" => [qw( pauseid )],
    };
  },
);

1;
