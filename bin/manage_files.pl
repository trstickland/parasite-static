#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

To provide a directory structure for static files for every genome in the core databases, creating
new directories where they do not yet exist:
 
   manage_files.pl
   
To look for all the expected markdown files for all B<published> genomes (the ones on the
WBPS web site), and list any that are missing
   
   manage_files.pl --find_missing

To create "placeholder" markdown files for all B<unpublished> genomes (those with a core database
but not yet on the web site), i.e. the files that need to be created for the next release:

   manage_files.pl --placeholders
   
=cut

use warnings;
use strict;
use feature 'say';

use ProductionMysql;

use Carp;
use File::Slurp;
use File::Touch;
use Getopt::Long;
use IO::Socket::SSL;
use Text::Markdown;
use Try::Tiny;
use WWW::Mechanize;

BEGIN{
   foreach my $required (qw(PARASITE_VERSION ENSEMBL_VERSION WORMBASE_VERSION)) {
      die "$required environment variable is not defined (PARASITE_VERSION, ENSEMBL_VERSION and WORMBASE_VERSION all required): baling"
         unless defined $ENV{$required} && length $ENV{$required};
   }
}

use constant CORE_DB_REGEX       => qr/^([a-z]+_[a-z0-9]+)_([a-z0-9]+)_core_$ENV{PARASITE_VERSION}_$ENV{ENSEMBL_VERSION}_[0-9]+$/;
use constant WBPS_BASE_URL       => 'https://parasite.wormbase.org/';
use constant ROOT_DIR            => './species';
use constant SPECIES_MD_FILES    => ['.about.md'];
use constant BIOPROJECT_MD_FILES => ['.assembly.md', '.annotation.md', '.referenced.md'];
use constant PLACEHOLDER_SUFFIX  => '.placeholder';


my $root_dir = ROOT_DIR;
my ($find_missing,$create_missing,$placeholders,$help);
GetOptions ("root_dir=s"      => \$root_dir,
            "find_missing"    => \$find_missing,
            "create_missing"  => \$create_missing,
            "placeholders"    => \$placeholders,
            "help"            => \$help,
            )
            || die "failed to parse command line arguments";
$help && die   "Usage:    $0 [options]\n\n"
            .  "Options:  --root_dir         root of new species/bioproject directory structure; default \"".ROOT_DIR."\"\n"
            .  "          --find_missing     find missing markdown files for published genomes\n"
            .  "          --create_missing   create missing markdown files for published genomes from website content\n"
            .  "          --placeholders     create placeholder markdown files for unpublished genomes\n"
            .  "          --help             this message\n"
            ;

my $wwwmech =  WWW::Mechanize->new( autocheck   => 1,
                                    ssl_opts    => {  SSL_verify_mode   => IO::Socket::SSL::SSL_VERIFY_NONE,
                                                      verify_hostname   => 0,
                                                      },
                                    )
               || die "failed to instantiate WWW::Mechanize: $!";
            
my %species_count = ();
CORE: foreach my $this_core_db ( ProductionMysql->staging->core_databases() ) {
  
   my($species, $bioproject);
   if( $this_core_db =~ CORE_DB_REGEX) {
      $species    = $1;
      $bioproject = $2;
   } else {
      # say "Ignoring: $this_core_db";
      next CORE
   }

   # core database names all lowercase, but paths on WBPS web site have capitalized genus
   $species = ucfirst($species);
   
   # get/create subdirectory for the bioproject
   my $species_dir            = join('/',$root_dir, $species);
   my $species_base_name      = $species;
   my $bioproject_dir         = create_subdir($root_dir, $species_base_name, $bioproject);
   my $bioproject_base_name   = $species.'_'.uc($bioproject);

   # get genome page from WBPS
   # path on WBPS web site is like "Acanthocheilonema_viteae_prjeb1697" (note capitalized genus)
   try {
      $wwwmech->get( WBPS_BASE_URL.$species.'_'.$bioproject );
      if($find_missing) {
         # print list of markdown files that are missing
         unless($species_count{$species}) {
            map {say} @{find_missing_md($species_dir,$species_base_name,SPECIES_MD_FILES)};
         }
         map {say} @{find_missing_md($bioproject_dir,$bioproject_base_name,BIOPROJECT_MD_FILES)};
      }
      if($create_missing) {
         # create markdown files that are missing or empty
         my %md_files   = (   about       => join('/', $species_dir,     "${bioproject_base_name}_about.md"),
                              assembly    => join('/', $bioproject_dir,  "${bioproject_base_name}_assembly.md"),
                              annotation  => join('/', $bioproject_dir,  "${bioproject_base_name}_annotation.md"),
                           );
         my $something_missing = 0;
         foreach my $f (values %md_files) {
            ++$something_missing unless -s $f;
         }
         if( $something_missing ) {
            my $content = extract_content($wwwmech);
            foreach my $k (keys %md_files) {
               my $filename = $md_files{$k};
               unless(-s $filename) {
                  my $content = join("\n",@{$content->{$k}},'');
                  File::Slurp::overwrite_file($filename, {binmode => ':utf8'}, $content) || die "failed to write $filename: $!";
                  say $filename;
               }
            } # foreach my $k
         } # if( $something_missing )
      } # if($create_missing)
   } catch {
      my $msg = $_;
      # 404 is expected for new genomes; anything else is an error
      unless('404' eq $wwwmech->status()) {
         confess $msg;
      }
      # say "Not yet published: ${species}_${bioproject}".($placeholders?' (creating placeholders)':'');
      if($placeholders) {
         unless($species_count{$species}) {
            map {say} @{create_placeholders($species_dir,$species,SPECIES_MD_FILES)};
         }
         map {say} @{create_placeholders($bioproject_dir,$bioproject_base_name,BIOPROJECT_MD_FILES)};
      }
   };
   
   ++$species_count{$species};   
}

# extracts "about", "assembly" and "annotation" section content from web site page
# pass a WWW::Mechanize object that has requested a page
# returns reference to hash with content of each section
# content is ref to array of string(s)
sub extract_content
{  my $this = (caller(0))[3];
   my $wwwmech = shift();
   die "$this requires reference to WWW::Mechanize object"
      unless $wwwmech && 'WWW::Mechanize' eq ref($wwwmech);
      
   my $parser;
   try {
      $parser = new WBPSParser->parse($wwwmech->content()) || die "HTML parsing error: $!";
   } catch {
      my $msg = $_;
      die "Failed to parse ".scalar($wwwmech->uri()).": $msg";
   };
   
   return(  {  about       => $parser->section_content('about', 'html'),
               assembly    => $parser->section_content('assembly', 'html'),
               annotation  => $parser->section_content('annotation', 'html'),
               }
            );
}

# creates root->species->bioproject subirectory structure as required
# returns path of bioproject subd irectory
sub create_subdir
{  my $this = (caller(0))[3];
   my($root, $species, $bioproject) = @_;
   die "$this requires root directory, species and bioproject" unless $root && $species && $bioproject;

   my $species_dir      = join('/',$root, $species);
   my $bioproject_dir   = join('/',$root, $species, uc($bioproject));
   
   for my $this_dir ($root, $species_dir, $bioproject_dir) {
      if(-e $this_dir) {
         -d $this_dir || die "$this_dir exists, but isn't a directory";
      } else {
         mkdir($this_dir) || die "Couldn't create directory $this_dir: $!";
         touch(join('/',$this_dir,'.created'));
      }
   }
   
   return( $bioproject_dir );
}

# looks for missing MD files in a directory
# pass directory path, file name base and expected file suffixes
# returns ref to array of paths of missing files
sub find_missing_md
{  my($dir, $base, $expected) = @_;
   
   my $missing = [];
   list_md_files( $dir,
                  $base,
                  $expected,
                  sub{  my $this_file = shift();
                        unless( -e $this_file ) {
                           push( @{$missing}, $this_file );
                        }     
                     }
                  );
      
   return( $missing );
}

# looks for missing MD files in a directory, and creates placeholders
# pass directory path, file name base and expected file suffixes
# returns ref to array of paths of placeholder files
# (N.B. if there were any placeholder files already in existence,
# these are included in the array referenced by the return value)
sub create_placeholders
{  my($dir, $base, $expected) = @_;

   my $placeholders = [];
   list_md_files( $dir,
                  $base,
                  $expected,
                  sub{  my $this_file = shift();
                        unless(-e $this_file) {
                           my $placeholder = $this_file.PLACEHOLDER_SUFFIX;
                           -e $placeholder || touch($placeholder);
                           push( @{$placeholders}, $placeholder );
                        }
                     }
                  );
   
   return( $placeholders );
}

# provides list of MD files that are expected to exist in a directory
# pass directory path, file name base, and expected file suffixes
# returns ref to array of paths of expected files
sub list_md_files
{  my $this = (caller(0))[3];
   my($dir, $base, $expected, $callback) = @_;
   confess "$this requires directory"              unless $dir && -d $dir;
   confess "$this requires file name base"         unless $base;
   confess "$this requires list of expected files" unless $expected  && ref([])    eq ref($expected);
   confess "$this callabck must be CODE ref"       unless !$callback || ref(sub{}) eq ref($callback);

   my @files = map($dir.'/'.$base.$_, @{$expected});
   
   if($callback) {
      map( $callback->($_), @files );
   }
   
   return( \@files );
}



package WBPSParser;

use Carp;
use HTML::Parser;
use HTML::Entities;
use base qw(HTML::Parser);

# returns name of section being parsed currently
# any value that evaluates false indicates not currently parsing a section of interest
# if a value is passed, this is set and returned
sub current_section
{  my($self,$which) = @_;
   $self->{__WITHIN_SECTION__} = $which if defined $which;
   return($self->{__WITHIN_SECTION__});
}

# returns content of named section, as ref to (possibly empty) array
# params:
#   1 - the name of the section (e.g. 'about')
#   2 - the type of content ('html' or 'text')
#   3 - OPTIONAL: content to be stored
# if the 3rd param is a scalar value, it is pushed to the content before the (complete) content is returned
# if the 3rd param is an array ref, it is assigned (deleting any exist content) and the new content returned
sub section_content
{  my($self,$which,$type,$new) = @_;
   my $this = (caller(0))[3];
   confess "$this requires name of type of content being accessed: 'html' or 'text'" unless $type && grep {$_ eq $type} qw(html text);
   confess "$this requires name of section currently being parsed" unless $which;
   if(defined $new) {
      if( ref([]) eq ref($new) ) {
         $self->{__SECTION_CONTENT__}->{$which}->{$type} = $new;
      } elsif( ref($new) ) {
         confess "new content passed to $this must be an ARRAY ref or scalar";
      } else {
         $self->{__SECTION_CONTENT__}->{$which}->{$type} = [] unless exists $self->{__SECTION_CONTENT__}->{$which}->{$type};
         push( @{$self->{__SECTION_CONTENT__}->{$which}->{$type}}, $new);
      }
   }
   return(  exists $self->{__SECTION_CONTENT__}->{$which}->{$type}
               ? $self->{__SECTION_CONTENT__}->{$which}->{$type}
               : []
            );
}


sub start
{  my ($self, $tagname, $attr, $attrseq, $text) = @_;

   # all sections of interest start with an 'a' element with a 'name' attribute
   # with the value "about"  "assembly" or "annotation"
   # e.g.  <a name="about">
   if('a' eq $tagname && $attr && exists $attr->{name} && grep {$_ eq $attr->{name}} qw(about assembly annotation) ) {
      $self->current_section($attr->{name});
   }
   
   # encountering an h3 within annotation or assembly indicated the end of that section
   if('h3' eq $tagname && ('assembly' eq $self->current_section() || 'annotation' eq $self->current_section()) ) {
      $self->current_section(0);
   }
   
   # if currently parsing a section, content should be stored
   # (this captures the opening tag of the sectiopn, and tags within the section)
   if($self->current_section()){
      $self->section_content($self->current_section(), html => $text)
   }
}

sub end
{  my ($self, $tagname, $text) = @_;
   return unless $self->current_section();
   
   # if currently parsing a section, content should be stored
   # (this captures the closing tag of the section, and tags within the section)
   if($self->current_section()){
      $self->section_content($self->current_section(), html => $text)
   }
   
   # all sections end if </div> encountered
   if('div' eq $tagname) {
      $self->current_section(0);
   }
}

sub text
{  my ($self, $origtext) = @_;
   return unless $self->current_section();
   
   $self->section_content( $self->current_section(), html => $origtext );

   my $dtext = decode_entities($origtext);
   # remove leading and trailing whitespace; compress whitespace
   chomp($dtext); $dtext =~ s/^\s+//; $dtext =~ s/\s+$//; $dtext =~ s/\s+/ /g;
   # store the text, provided it's not empty
   $self->section_content( $self->current_section(), text => $dtext ) if $dtext;
}

1;
