use strict;
use warnings;
package local::c;
{
  $local::c::VERSION = '0.001';
}
# ABSTRACT: Installing C libraries in userspace [HIGHLY EXPERIMENTAL]

#
# this code is mostly forked of local::lib
#
use 5.008001;

use File::Spec ();
use File::Path ();
use Carp ();
use Config;

our $VERSION ||= '0.000';

our @KNOWN_FLAGS = qw(--deactivate --deactivate-all --print-env);

our $DEFAULT_PATH = '~/localc';

sub DEACTIVATE_ONE () { 1 }
sub DEACTIVATE_ALL () { 2 }
 
sub INTERPOLATE_ENV () { 1 }
sub LITERAL_ENV     () { 0 }
 
sub import {
  my ($class, @args) = @_;
 
  my %arg_store;
  for my $arg (@args) {
    # check for lethal dash first to stop processing before causing problems
    if ($arg =~ /−/) {
      die <<'DEATH';
WHOA THERE! It looks like you've got some fancy dashes in your commandline!
These are *not* the traditional -- dashes that software recognizes. You
probably got these by copy-pasting from the perldoc for this module as
rendered by a UTF8-capable formatter. This most typically happens on an OS X
terminal, but can happen elsewhere too. Please try again after replacing the
dashes with normal minus signs.
DEATH
    } elsif(grep { $arg eq $_ } @KNOWN_FLAGS) {
      (my $flag = $arg) =~ s/--//;
      $arg_store{$flag} = 1;
    } elsif($arg =~ /^--/) {
      die "Unknown import argument: $arg";
    } else {
      # assume that what's left is a path
      $arg_store{path} = $arg;
    }
  }
 
  my $printenv = defined $arg_store{'print-env'} ? 1 : 0;
 
  my $deactivating = 0;
  if ($arg_store{deactivate}) {
    $deactivating = DEACTIVATE_ONE;
  }
  if ($arg_store{'deactivate-all'}) {
    $deactivating = DEACTIVATE_ALL;
  }
 
  $arg_store{path} = $class->resolve_path($arg_store{path});
  $class->setup_local_c_for($arg_store{path}, $deactivating, $printenv);
 
}
 
sub pipeline;
 
sub pipeline {
  my @methods = @_;
  my $last = pop(@methods);
  if (@methods) {
    \sub {
      my ($obj, @args) = @_;
      $obj->${pipeline @methods}(
        $obj->$last(@args)
      );
    };
  } else {
    \sub {
      shift->$last(@_);
    };
  }
}
 
 
sub _uniq {
  my %seen;
  grep { ! $seen{$_}++ } @_;
}
 
sub resolve_path {
  my ($class, $path) = @_;
  $class->${pipeline qw(
    resolve_relative_path
    resolve_home_path
    resolve_empty_path
  )}($path);
}
 
sub resolve_empty_path {
  my ($class, $path) = @_;
  if (defined $path) {
    $path;
  } else {
    $DEFAULT_PATH;
  }
}
 
 
sub resolve_home_path {
  my ($class, $path) = @_;
  return $path unless ($path =~ /^~/);
  my ($user) = ($path =~ /^~([^\/]+)/); # can assume ^~ so undef for 'us'
  my $tried_file_homedir;
  my $homedir = do {
    if (eval { require File::HomeDir } && $File::HomeDir::VERSION >= 0.65) {
      $tried_file_homedir = 1;
      if (defined $user) {
        File::HomeDir->users_home($user);
      } else {
        File::HomeDir->my_home;
      }
    } else {
      if (defined $user) {
        (getpwnam $user)[7];
      } else {
        if (defined $ENV{HOME}) {
          $ENV{HOME};
        } else {
          (getpwuid $<)[7];
        }
      }
    }
  };
  unless (defined $homedir) {
    Carp::croak(
      "Couldn't resolve homedir for "
      .(defined $user ? $user : 'current user')
      .($tried_file_homedir ? '' : ' - consider installing File::HomeDir')
    );
  }
  $path =~ s/^~[^\/]*/$homedir/;
  $path;
}
 
sub resolve_relative_path {
  my ($class, $path) = @_;
  $path = File::Spec->rel2abs($path);
}
 
sub setup_local_c_for {
  my ($class, $path, $deactivating, $printenv) = @_;
 
  my $interpolate = LITERAL_ENV;
  my @active_lcs = $class->active_paths;
 
  $path = $class->ensure_dir_structure_for($path);
 
  if (! $deactivating) {
    if (@active_lcs && $active_lcs[-1] eq $path) {
      exit 0 if $0 eq '-';
      return; # Asked to add what's already at the top of the stack
    } elsif (grep { $_ eq $path} @active_lcs) {
      # Asked to add a dir that's lower in the stack -- so we remove it from
      # where it is, and then add it back at the top.
      $class->setup_env_hash_for($path, DEACTIVATE_ONE);
      # Which means we can no longer output "PERL5LIB=...:$PERL5LIB" stuff
      # anymore because we're taking something *out*.
      $interpolate = INTERPOLATE_ENV;
    }
  }
 
  if ($0 eq '-' or $printenv) {
    $class->print_environment_vars_for($path, $deactivating, $interpolate);
    exit 0;
  } else {
    $class->setup_env_hash_for($path, $deactivating);
  }
}
 
sub install_base_bin_path {
  my ($class, $path) = @_;
  File::Spec->catdir($path, 'bin');
}

sub install_base_pkg_config_path {
  my ($class, $path) = @_;
  File::Spec->catdir($path, 'lib', 'pkgconfig');
}
 
sub ensure_dir_structure_for {
  my ($class, $path) = @_;
  unless (-d $path) {
    warn "Attempting to create directory ${path}\n";
  }
  File::Path::mkpath($path);
  # Need to have the path exist to make a short name for it, so
  # converting to a short name here.
  $path = Win32::GetShortPathName($path) if $^O eq 'MSWin32';
 
  return $path;
}
 
sub guess_shelltype {
  my $shellbin = 'sh';
  if(defined $ENV{'SHELL'}) {
      my @shell_bin_path_parts = File::Spec->splitpath($ENV{'SHELL'});
      $shellbin = $shell_bin_path_parts[-1];
  }
  my $shelltype = do {
      local $_ = $shellbin;
      if(/csh/) {
          'csh'
      } else {
          'bourne'
      }
  };
 
  # Both Win32 and Cygwin have $ENV{COMSPEC} set.
  if (defined $ENV{'COMSPEC'} && $^O ne 'cygwin') {
      my @shell_bin_path_parts = File::Spec->splitpath($ENV{'COMSPEC'});
      $shellbin = $shell_bin_path_parts[-1];
         $shelltype = do {
                 local $_ = $shellbin;
                 if(/command\.com/) {
                         'win32'
                 } elsif(/cmd\.exe/) {
                         'win32'
                 } elsif(/4nt\.exe/) {
                         'win32'
                 } else {
                         $shelltype
                 }
         };
  }
  return $shelltype;
}
 
sub print_environment_vars_for {
  my ($class, $path, $deactivating, $interpolate) = @_;
  print $class->environment_vars_string_for($path, $deactivating, $interpolate);
}
 
sub environment_vars_string_for {
  my ($class, $path, $deactivating, $interpolate) = @_;
  my @envs = $class->build_environment_vars_for($path, $deactivating, $interpolate);
  my $out = '';
 
  # rather basic csh detection, goes on the assumption that something won't
  # call itself csh unless it really is. also, default to bourne in the
  # pathological situation where a user doesn't have $ENV{SHELL} defined.
  # note also that shells with funny names, like zoid, are assumed to be
  # bourne.
 
  my $shelltype = $class->guess_shelltype;
 
  while (@envs) {
    my ($name, $value) = (shift(@envs), shift(@envs));
    $value =~ s/(\\")/\\$1/g if defined $value;
    $out .= $class->${\"build_${shelltype}_env_declaration"}($name, $value);
  }
  return $out;
}
 
# simple routines that take two arguments: an %ENV key and a value. return
# strings that are suitable for passing directly to the relevant shell to set
# said key to said value.
sub build_bourne_env_declaration {
  my $class = shift;
  my($name, $value) = @_;
  return defined($value) ? qq{export ${name}="${value}";\n} : qq{unset ${name};\n};
}
 
sub build_csh_env_declaration {
  my $class = shift;
  my($name, $value) = @_;
  return defined($value) ? qq{setenv ${name} "${value}"\n} : qq{unsetenv ${name}\n};
}
 
sub build_win32_env_declaration {
  my $class = shift;
  my($name, $value) = @_;
  return defined($value) ? qq{set ${name}=${value}\n} : qq{set ${name}=\n};
}
 
sub setup_env_hash_for {
  my ($class, $path, $deactivating) = @_;
  my %envs = $class->build_environment_vars_for($path, $deactivating, INTERPOLATE_ENV);
  @ENV{keys %envs} = values %envs;
}
 
sub build_environment_vars_for {
  my ($class, $path, $deactivating, $interpolate) = @_;
 
  if ($deactivating == DEACTIVATE_ONE) {
    return $class->build_deactivate_environment_vars_for($path, $interpolate);
  } elsif ($deactivating == DEACTIVATE_ALL) {
    return $class->build_deact_all_environment_vars_for($path, $interpolate);
  } else {
    return $class->build_activate_environment_vars_for($path, $interpolate);
  }
}
 
sub build_activate_environment_vars_for {
  my ($class, $path, $interpolate) = @_;
  return (
    LOCAL_C_PREFIX => $path,
    LOCAL_C_PREFIXES =>
      join($Config{path_sep},
        ( $ENV{LOCAL_C_PREFIXES}
          ? ( $interpolate == INTERPOLATE_ENV
              ? ( $ENV{LOCAL_C_PREFIXES} || () )
              : ( ($^O ne 'MSWin32') ? '$LOCAL_C_PREFIXES' : '%LOCAL_C_PREFIXES%' )
            )
          : ()
        ),
        $path
      ),
    PKG_CONFIG_PATH =>
      join($Config{path_sep},
        $class->install_base_pkg_config_path($path),
        ( $interpolate == INTERPOLATE_ENV
          ? ( $ENV{PKG_CONFIG_PATH} || () )
          : ( $ENV{PKG_CONFIG_PATH}
              ? ( ($^O ne 'MSWin32') ? '$PKG_CONFIG_PATH' : '%PKG_CONFIG_PATH%' )
              : ()
            )
        )
      ),
    PATH =>
      join($Config{path_sep},
        $class->install_base_bin_path($path),
        ( $interpolate == INTERPOLATE_ENV
          ? ( $ENV{PATH} || () )
          : ( ($^O ne 'MSWin32') ? '$PATH' : '%PATH%' )
        )
      ),
  );
}
 
sub active_paths {
  my ($class) = @_;
 
  return () unless defined $ENV{LOCAL_C_PREFIXES};
  return split /\Q$Config{path_sep}/, $ENV{LOCAL_C_PREFIXES};
}
 
sub build_deactivate_environment_vars_for {
  my ($class, $path, $interpolate) = @_;
 
  my @active_lcs = $class->active_paths;
 
  if (!grep { $_ eq $path } @active_lcs) {
    warn "Tried to deactivate inactive local::c '$path'\n";
    return ();
  }
 
  my @new_lc_root = grep { $_ ne $path } @active_lcs;
 
  my %env = (
    LOCAL_C_PREFIX => (@active_lcs ? $active_lcs[0] : undef),
    LOCAL_C_PREFIXES => (@new_lc_root ?
      join($Config{path_sep}, @new_lc_root) : undef
    ),
    PATH => join($Config{path_sep},
      grep { $_ ne $class->install_base_bin_path($path) }
      split /\Q$Config{path_sep}/, $ENV{PATH}
    ),
    PKG_CONFIG_PATH => join($Config{path_sep},
      grep { $_ ne $class->install_base_pkg_config_path($path) }
      split /\Q$Config{path_sep}/, $ENV{PKG_CONFIG_PATH}
    ),
  );
 
  return %env;
}
 
sub build_deact_all_environment_vars_for {
  my ($class, $path, $interpolate) = @_;
 
  my @active_lcs = $class->active_paths;
 
  my @new_path = split /\Q$Config{path_sep}/, $ENV{PATH};
  my @new_pkg_config = split /\Q$Config{path_sep}/, $ENV{PKG_CONFIG_PATH};
 
  for my $path (@active_lcs) {
    @new_path = grep {
      $_ ne $class->install_base_bin_path($path)
    } @new_path;
    @new_pkg_config = grep {
      $_ ne $class->install_base_pkg_config_path($path)
    } @new_pkg_config;
  }
  
  my %env = (
    LOCAL_C_PREFIXES => undef,
    PATH => join($Config{path_sep}, @new_path),
    PKG_CONFIG_PATH => join($Config{path_sep}, @new_pkg_config),
  );
 
  return %env;
}

1;


__END__
=pod

=head1 NAME

local::c - Installing C libraries in userspace [HIGHLY EXPERIMENTAL]

=head1 VERSION

version 0.001

=head1 DESCRIPTION

B<HIGHLY EXPERIMENTAL - IF YOU WANNA USE IT, CONTACT US ON IRC, _PLEASE_>

=head1 SUPPORT

IRC:

    Join #local-c on irc.perl.org.

=head1 AUTHOR

Torsten Raudssus <torsten@raudss.us>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2012 by the local::c "AUTHOR" as listed above.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

