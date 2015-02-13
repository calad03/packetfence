package pfconfig::manager;

=head1 NAME

pfconfig::manager

=cut

=head1 DESCRIPTION

pfconfig::manager

This module controls the access, buikd and expiration of the config namespaces

This module will serve as an interface to build and cache the namespaces

It will first search in the raw in-memory cache, then the layer 2 backend (pfconfig::backend),
then it will build the associated object of the namespace

=cut

=head1 USAGE

In order to access the configuration namespaces : 
- Instanciate the object
- Then call get_cache on a specific namespace in order to fetch it
- The classes that build the namespaces are located in pfconfig::namespaces

=cut


use strict;
use warnings;

#use Cache::BDB;
use Cache::Memcached;
use Config::IniFiles;
use List::MoreUtils qw(any firstval uniq);
use Scalar::Util qw(refaddr reftype tainted blessed);
use UNIVERSAL::require;
use Data::Dumper;
use pfconfig::backend::memcached;
use pfconfig::log;
use Time::HiRes qw(stat time);

sub config_builder {
  my ($self, $namespace) = @_;
  my $logger = get_logger;

  my $elem = $self->get_namespace($namespace);
  my $tmp = $elem->build();

  return $tmp;
};

sub get_namespace {
  my ($self, $name) = @_;
  my $logger = get_logger;
   my $type = "pfconfig::namespaces::$name";

  # load the module to instantiate
  if ( !(eval "$type->require()" ) ) {
      $logger->error( "Can not load namespace $name "
          . "Read the following message for details: $@" );
  }

  my $elem = $type->new($self); 

  return $elem;
}

sub new {
  my ($class) = @_;
  my $self = bless {}, $class;

  $self->init_cache();

  return $self;
}

sub init_cache {
  my ($self) = @_;
  my $logger = get_logger;

  $self->{cache} = pfconfig::backend::memcached->new;

  $self->{memory} = {};
  $self->{memorized_at} = {};
}

# update the timestamp on the control file
# send the signal that the raw memory is expired
sub touch_cache {
  my ($self, $what) = @_;
  my $logger = get_logger;
  $what =~ s/\//;/g;
  my $filename = "/usr/local/pf/var/$what-control";
  `touch $filename`;
  #open HANDLE, ">>$filename" or die "touch $filename: $!\n"; 
  #close HANDLE;
  #my $now = time;
  #utime $now, $now, "$filename";
}

# get a key in the cache
sub get_cache {
  my ($self, $what) = @_;
  my $logger = get_logger;
  # we look in raw memory and make sure that it's not expired
  my $memory = $self->{memory}->{$what};
  if(defined($memory) && $self->is_valid($what)){
    $logger->debug("Getting $what from memory");
    return $memory;
  }
  else {
    my $cached = $self->{cache}->get($what);
    # raw memory is expired but cache is not
    if($cached){
      $logger->debug("Getting $what from cache backend");
      $self->{memory}->{$what} = $cached;
      $self->{memorized_at}->{$what} = time; 
      return $cached;
    }
    # everything is expired. need to rebuild completely
    else {
      my $result = $self->cache_resource($what);
      return $result;
    }
  }
 
}

sub cache_resource {
    my ($self, $what) = @_;
    my $logger = get_logger;

    $logger->debug("loading $what from outside");
    my $result = $self->config_builder($what);
    my $cache_w = $self->{cache}->set($what, $result, 864000) ;
    $logger->trace("Cache write gave : $cache_w");
    $self->touch_cache($what);
    $self->{memory}->{$what} = $result;
    $self->{memorized_at}->{$what} = time; 

    return $result;

}

# helper to know if the raw memory cache is still valid
sub is_valid {
  my ($self, $what) = @_;
  my $logger = get_logger;
  my $control_file;
  ($control_file = $what) =~ s/\//;/g;
  my $file_timestamp = (stat("/usr/local/pf/var/".$control_file."-control"))[9];

  unless(defined($file_timestamp)){
    $logger->warn("Filesystem timestamp is not set for $what. Setting it as now and considering memory as invalid.");
    $self->touch_cache($what);
    return 0;
  }

  my $memory_timestamp = $self->{memorized_at}->{$what};
  $logger->trace("Control file has timestamp $file_timestamp and memory has timestamp $memory_timestamp for key $what");
  # if the timestamp of the file is after the one we have in memory
  # then we are expired
  if ($memory_timestamp > $file_timestamp){
    $logger->trace("Memory configuration is still valid for key $what");
    return 1;
  }
  else{
    $logger->info("Memory configuration is not valid anymore for key $what");
    return 0;
  }
}

# expire a key in the cache and rebuild it
# will expire the memory cache after building
sub expire {
  my ($self, $what) = @_;
  my $logger = get_logger;
  $logger->info("Expiring resource : $what");
  $self->cache_resource($what);

  my $namespace = $self->get_namespace($what);
  if ($namespace->{child_resources}){
    foreach my $child_resource (@{$namespace->{child_resources}}){
      $logger->info("Expiring child resource $child_resource. Master resource is $what");
      $self->expire($child_resource);
    }
  }

}

sub list_namespaces {
  my ($self, $what) = @_;
  
}

=back

=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2015 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;

# vim: set shiftwidth=4:
# vim: set expandtab:
# vim: set backspace=indent,eol,start:
