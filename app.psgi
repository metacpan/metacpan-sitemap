use v5.36;
use MetaCPAN::Sitemaps ();

my $sitemaps = MetaCPAN::Sitemaps->new;
$sitemaps->config->init_logger;

$sitemaps->to_app;
