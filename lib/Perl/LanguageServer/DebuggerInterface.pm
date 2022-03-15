#
# We include DB package from perl core here, to be able to modify it...
#

package DB;

# "private" globals

my ($running, $ready, $deep, $usrctxt, $evalarg, 
    @stack, @saved, @skippkg, @clients);
my $preeval = {};
my $posteval = {};
my $ineval = {};

####
#
# Globals - must be defined at startup so that clients can refer to 
# them right after a C<require DB;>
#
####

BEGIN {

  # these are hardcoded in perl source (some are magical)

  $DB::sub = '';        # name of current subroutine
  %DB::sub = ();        # "filename:fromline-toline" for every known sub
  $DB::single = 0;      # single-step flag (set it to 1 to enable stops in BEGIN/use)
  $DB::signal = 0;      # signal flag (will cause a stop at the next line)
  $DB::trace = 0;       # are we tracing through subroutine calls?
  @DB::args = ();       # arguments of current subroutine or @ARGV array
  @DB::dbline = ();     # list of lines in currently loaded file
  %DB::dbline = ();     # actions in current file (keyed by line number)
  @DB::ret = ();        # return value of last sub executed in list context
  $DB::ret = '';        # return value of last sub executed in scalar context

  # other "public" globals  

  $DB::package = '';    # current package space
  $DB::filename = '';   # current filename
  $DB::subname = '';    # currently executing sub (fully qualified name)
  $DB::lineno = '';     # current line number

  $DB::VERSION = $DB::VERSION = '1.07';

  # initialize private globals to avoid warnings

  $running = 1;         # are we running, or are we stopped?
  @stack = (0);
  @clients = ();
  $deep = 1000;
  $ready = 0;
  @saved = ();
  @skippkg = ();
  $usrctxt = '';
  $evalarg = '';
}

####
# entry point for all subroutine calls
#
sub sub {

  # this is important, othwise return values might be corrupted...
  return &$DB::sub if (!$DB::single) ;

  push(@stack, $DB::single);
  $DB::single &= 1;
  $DB::single |= 4 if $#stack == $deep;
  if ($DB::sub eq 'DESTROY' or substr($DB::sub, -9) eq '::DESTROY' or not defined wantarray) {
    &$DB::sub;
    $DB::single |= pop(@stack);
    $DB::ret = undef;
  }
  elsif (wantarray) {
    @DB::ret = &$DB::sub;
    $DB::single |= pop(@stack);
    @DB::ret;
  }
  else {
    $DB::ret = &$DB::sub;
    $DB::single |= pop(@stack);
    $DB::ret;
  }
}

####
# this is called by perl for every statement
#
sub DB {
  return unless $ready;
  &save;
  ($DB::package, $DB::filename, $DB::lineno) = caller;

  return if @skippkg and grep { $_ eq $DB::package } @skippkg;

  $usrctxt = "package $DB::package;";		# this won't let them modify, alas
  local(*DB::dbline) = "::_<$DB::filename";

  my ($stop, $action);
  if (($stop,$action) = split(/\0/,$DB::dbline{$DB::lineno})) {
    if ($stop eq '1') {
      $DB::signal |= 1;
    }
    else {
      $stop = 0 unless $stop;			# avoid un_init warning
      $evalarg = "\$DB::signal |= do { $stop; }"; &eval;
      $DB::dbline{$DB::lineno} =~ s/;9($|\0)/$1/;    # clear any temp breakpt
    }
  }
  if ($DB::single || $DB::trace || $DB::signal) {
    $DB::subname = ($DB::sub =~ /\'|::/) ? $DB::sub : "${DB::package}::$DB::sub"; #';
    DB->loadfile($DB::filename, $DB::lineno);
  }
  $evalarg = $action, &eval if $action;
  if ($DB::single || $DB::signal) {
    _outputall($#stack . " levels deep in subroutine calls.\n") if $DB::single & 4;
    $DB::single = 0;
    $DB::signal = 0;
    $running = 0;
    
    &eval if ($evalarg = DB->prestop);
    my $c;
    for $c (@clients) {
      # perform any client-specific prestop actions
      &eval if ($evalarg = $c->cprestop);
      
      # Now sit in an event loop until something sets $running
      do {
	$c->idle;                     # call client event loop; must not block
	if ($running == 2) {          # client wants something eval-ed
	  &eval if ($evalarg = $c->evalcode);
	  $running = 0;
	}
      } until $running;
      
      # perform any client-specific poststop actions
      &eval if ($evalarg = $c->cpoststop);
    }
    &eval if ($evalarg = DB->poststop);
  }
  ($@, $!, $,, $/, $\, $^W) = @saved;
  ();
}
  
####
# this takes its argument via $evalarg to preserve current @_
#    
sub eval {
  ($@, $!, $,, $/, $\, $^W) = @saved;
  eval "$usrctxt $evalarg; &DB::save";
  _outputall($@) if $@;
}

###############################################################################
#         no compile-time subroutine call allowed before this point           #
###############################################################################

use strict;                # this can run only after DB() and sub() are defined

sub save {
  @saved = ($@, $!, $,, $/, $\, $^W);
  $, = ""; $/ = "\n"; $\ = ""; $^W = 0;
}

sub catch {
  for (@clients) { $_->awaken; }
  $DB::signal = 1;
  $ready = 1;
}

####
#
# Client callable (read inheritable) methods defined after this point
#
####

sub register {
  my $s = shift;
  $s = _clientname($s) if ref($s);
  push @clients, $s;
}

sub done {
  my $s = shift;
  $s = _clientname($s) if ref($s);
  @clients = grep {$_ ne $s} @clients;
  $s->cleanup;
#  $running = 3 unless @clients;
  exit(0) unless @clients;
}

sub _clientname {
  my $name = shift;
  "$name" =~ /^(.+)=[A-Z]+\(.+\)$/;
  return $1;
}

sub next {
  my $s = shift;
  $DB::single = 2;
  $running = 1;
}

sub step {
  my $s = shift;
  $DB::single = 1;
  $running = 1;
}

sub cont {
  my $s = shift;
  my $i = shift;
  $s->set_tbreak($i) if $i;
  for ($i = 0; $i <= $#stack;) {
	$stack[$i++] &= ~1;
  }
  $DB::single = 0;
  $running = 1;
}

####
# XXX caller must experimentally determine $i (since it depends
# on how many client call frames are between this call and the DB call).
# Such is life.
#
sub ret {
  my $s = shift;
  my $i = shift;      # how many levels to get to DB sub
  $i = 0 unless defined $i;
  $i -= $#stack-$i if ($#stack-$i < 0) ;
  $stack[$#stack-$i] |= 1;
  $DB::single = 0;
  $running = 1;
}

####
# XXX caller must experimentally determine $start (since it depends
# on how many client call frames are between this call and the DB call).
# Such is life.
#
sub backtrace {
  my $self = shift;
  my $start = shift;
  my($p,$f,$l,$s,$h,$w,$e,$r,$a, @a, @ret,$i);
  $start = 1 unless $start;
  for ($i = $start; ($p,$f,$l,$s,$h,$w,$e,$r) = caller($i); $i++) {
    @a = @DB::args;
    for (@a) {
      s/'/\\'/g;
      s/([^\0]*)/'$1'/ unless /^-?[\d.]+$/;
      s/([\200-\377])/sprintf("M-%c",ord($1)&0177)/eg;
      s/([\0-\37\177])/sprintf("^%c",ord($1)^64)/eg;
    }
    $w = $w ? '@ = ' : '$ = ';
    $a = $h ? '(' . join(', ', @a) . ')' : '';
    $e =~ s/\n\s*\;\s*\Z// if $e;
    $e =~ s/[\\\']/\\$1/g if $e;
    if ($r) {
      $s = "require '$e'";
    } elsif (defined $r) {
      $s = "eval '$e'";
    } elsif ($s eq '(eval)') {
      $s = "eval {...}";
    }
    $f = "file '$f'" unless $f eq '-e';
    push @ret, "$w&$s$a from $f line $l";
    last if $DB::signal;
  }
  return @ret;
}

sub _outputall {
  my $c;
  for $c (@clients) {
    $c->output(@_);
  }
}

sub trace_toggle {
  my $s = shift;
  $DB::trace = !$DB::trace;
}


####
# without args: returns all defined subroutine names
# with subname args: returns a listref [file, start, end]
#
sub subs {
  my $s = shift;
  if (@_) {
    my(@ret) = ();
    while (@_) {
      my $name = shift;
      push @ret, [$DB::sub{$name} =~ /^(.*)\:(\d+)-(\d+)$/] 
	if exists $DB::sub{$name};
    }
    return @ret;
  }
  return keys %DB::sub;
}

####
# first argument is a filename whose subs will be returned
# if a filename is not supplied, all subs in the current
# filename are returned.
#
sub filesubs {
  my $s = shift;
  my $fname = shift;
  $fname = $DB::filename unless $fname;
  return grep { $DB::sub{$_} =~ /^$fname/ } keys %DB::sub;
}

####
# returns a list of all filenames that DB knows about
#
sub files {
  my $s = shift;
  my(@f) = grep(m|^_<|, keys %main::);
  return map { substr($_,2) } @f;
}

####
# returns reference to an array holding the lines in currently
# loaded file
#
sub lines {
  my $s = shift;
  return \@DB::dbline;
}

####
# loadfile($file, $line)
#
sub loadfile {
  my $s = shift;
  my($file, $line) = @_;
  if (!defined $main::{'_<' . $file}) {
    my $try;
    if (($try) = grep(m|^_<.*$file|, keys %main::)) {  
      $file = substr($try,2);
    }
  }
  if (defined($main::{'_<' . $file})) {
    my $c;
#    _outputall("Loading file $file..");
    *DB::dbline = "::_<$file";
    $DB::filename = $file;
    for $c (@clients) {
#      print "2 ", $file, '|', $line, "\n";
      $c->showfile($file, $line);
    }
    return $file;
  }
  return undef;
}

sub lineevents {
  my $s = shift;
  my $fname = shift;
  my(%ret) = ();
  my $i;
  $fname = $DB::filename unless $fname;
  local(*DB::dbline) = "::_<$fname";
  for ($i = 1; $i <= $#DB::dbline; $i++) {
    $ret{$i} = [$DB::dbline[$i], split(/\0/, $DB::dbline{$i})] 
      if defined $DB::dbline{$i};
  }
  return %ret;
}

sub set_break {
  my $s = shift;
  my $i = shift;
  my $cond = shift;
  $i ||= $DB::lineno;
  $cond ||= '1';
  $i = _find_subline($i) if ($i =~ /\D/);
  $s->output("Subroutine not found.\n") unless $i;
  if ($i) {
    if ($DB::dbline[$i] == 0) {
      $s->output("Line $i not breakable.\n");
    }
    else {
      $DB::dbline{$i} =~ s/^[^\0]*/$cond/;
    }
  }
}

sub set_tbreak {
  my $s = shift;
  my $i = shift;
  $i = _find_subline($i) if ($i =~ /\D/);
  $s->output("Subroutine not found.\n") unless $i;
  if ($i) {
    if ($DB::dbline[$i] == 0) {
      $s->output("Line $i not breakable.\n");
    }
    else {
      $DB::dbline{$i} =~ s/($|\0)/;9$1/; # add one-time-only b.p.
    }
  }
}

sub _find_subline {
  my $name = shift;
  $name =~ s/\'/::/;
  $name = "${DB::package}\:\:" . $name if $name !~ /::/;
  $name = "main" . $name if substr($name,0,2) eq "::";
  my($fname, $from, $to) = ($DB::sub{$name} =~ /^(.*):(\d+)-(\d+)$/);
  if ($from) {
    local *DB::dbline = "::_<$fname";
    ++$from while $DB::dbline[$from] == 0 && $from < $to;
    return wantarray?($from, $name, $fname):$from;
  }
  return undef;
}

sub clr_breaks {
  my $s = shift;
  my $i;
  if (@_) {
    while (@_) {
      $i = shift;
      $i = _find_subline($i) if ($i =~ /\D/);
      $s->output("Subroutine not found.\n") unless $i;
      if (defined $DB::dbline{$i}) {
        $DB::dbline{$i} =~ s/^[^\0]+//;
        if ($DB::dbline{$i} =~ s/^\0?$//) {
          delete $DB::dbline{$i};
        }
      }
    }
  }
  else {
    for ($i = 1; $i <= $#DB::dbline ; $i++) {
      if (defined $DB::dbline{$i}) {
        $DB::dbline{$i} =~ s/^[^\0]+//;
        if ($DB::dbline{$i} =~ s/^\0?$//) {
          delete $DB::dbline{$i};
        }
      }
    }
  }
}

sub set_action {
  my $s = shift;
  my $i = shift;
  my $act = shift;
  $i = _find_subline($i) if ($i =~ /\D/);
  $s->output("Subroutine not found.\n") unless $i;
  if ($i) {
    if ($DB::dbline[$i] == 0) {
      $s->output("Line $i not actionable.\n");
    }
    else {
      $DB::dbline{$i} =~ s/\0[^\0]*//;
      $DB::dbline{$i} .= "\0" . $act;
    }
  }
}

sub clr_actions {
  my $s = shift;
  my $i;
  if (@_) {
    while (@_) {
      my $i = shift;
      $i = _find_subline($i) if ($i =~ /\D/);
      $s->output("Subroutine not found.\n") unless $i;
      if ($i && $DB::dbline[$i] != 0) {
	$DB::dbline{$i} =~ s/\0[^\0]*//;
	delete $DB::dbline{$i} if $DB::dbline{$i} =~ s/^\0?$//;
      }
    }
  }
  else {
    for ($i = 1; $i <= $#DB::dbline ; $i++) {
      if (defined $DB::dbline{$i}) {
	$DB::dbline{$i} =~ s/\0[^\0]*//;
	delete $DB::dbline{$i} if $DB::dbline{$i} =~ s/^\0?$//;
      }
    }
  }
}

sub prestop {
  my ($client, $val) = @_;
  return defined($val) ? $preeval->{$client} = $val : $preeval->{$client};
}

sub poststop {
  my ($client, $val) = @_;
  return defined($val) ? $posteval->{$client} = $val : $posteval->{$client};
}

#
# "pure virtual" methods
#

# client-specific pre/post-stop actions.
sub cprestop {}
sub cpoststop {}

# client complete startup
sub awaken {}

sub skippkg {
  my $s = shift;
  push @skippkg, @_ if @_;
}

sub evalcode {
  my ($client, $val) = @_;
  if (defined $val) {
    $running = 2;    # hand over to DB() to evaluate in its context
    $ineval->{$client} = $val;
  }
  return $ineval->{$client};
}

sub ready {
  my $s = shift;
  return $ready = 1;
}

# stubs
    
sub init {}
sub stop {}
sub idle {}
sub cleanup {}
sub output {}

#
# client init
#
for (@clients) { $_->init }

$SIG{'INT'} = \&DB::catch;

# disable this if stepping through END blocks is desired
# (looks scary and deconstructivist with Swat)
END { $ready = 0 }


##############################################################################

package Perl::LanguageServer::DebuggerInterface ;

#use DB;

our @ISA = qw(DB); 

use strict ;

use IO::Socket ;
use JSON ;
use PadWalker ;
use Scalar::Util qw{blessed reftype looks_like_number};
use Hash::SafeKeys;
#use Data::Dump qw{pp} ;
use File::Basename ;
use vars qw{@dbline %dbline $dbline} ;

our $max_display = 5 ;
our $debug = 0 ;
our $session = $ENV{PLSDI_SESSION} || 1 ;
our $socket ;
our $json = JSON -> new -> utf8(1) -> ascii(1) ;
our @evalresult ;
our %postponed_breakpoints ;
our $breakpoint_id = 1 ;
our $loaded = 0 ;
our $break_reason ;
our $refresh ;

__PACKAGE__  -> register  ; 
__PACKAGE__  -> init  ; 

# ---------------------------------------------------------------------------

sub logger
    {
    my $class = shift ;
    print STDERR @_ ;
    }

# ---------------------------------------------------------------------------

use constant SPECIALS => { _ => 1, INC => 1, ARGV => 1, ENV => 1, ARGVOUT => 1, SIG => 1, 
                            STDIN => 1, STDOUT => 1, STDERR => 1,
                            stdin => 1, stdout => 1, stderr => 1} ;

use vars qw{%entry @entry $entry %stab} ;

# ---------------------------------------------------------------------------

sub get_globals 
    {
    my ($self, $package) = @_ ;

    my %vars ;

    my $specials = $package?0:1 ;
    $package ||= 'main' ;
    $package .= "::" unless $package =~ /::$/;
no strict ;
    *stab = *{"main::"};
    while ($package =~ /(\w+?::)/g)
        {
        *stab = ${stab}{$1};
        }
use strict ;        
    my $key ;
    my $val ;
    
    while (($key, $val) = each (%stab)) 
        {
        next if ($key eq '_') ;
        next if ($key =~ /^_</) ;
        next if ($key =~ /::$/) ;
        next if ($key eq 'stab') ;
        next if (!$specials && (SPECIALS -> {$key} || ($key !~ /^[a-zA-Z_]/))) ;
        next if ($specials && (!SPECIALS -> {$key} && ($key =~ /^[a-zA-Z_]/))) ;
        
        local(*entry) = $val;
        $key =~ s/([\0-\x1f])/'^'.chr(ord($1)+0x40)/eg ;

        $vars{"\$$key"} = [\$entry, 'eg:\\$' . $package . $key] if (defined $entry) ;
        $vars{"\@$key"} = [\@entry, 'eg:\\@' . $package . $key] if (@entry) ;
        $vars{"\%$key"} = [\%entry, 'eg:\\%' . $package . $key] if (%entry) ;
        #$vars{"\&$key"} = \&entry if (defined &entry) ;
        my $fileno;
        $vars{"Handle:$key"} = [\"fileno=$fileno"] if (defined ($fileno = eval{fileno(*entry)})) ;
        }
    
    return \%vars ;
    }

# ---------------------------------------------------------------------------

sub get_var_eval 
    {
    my ($self, $name, $varsrc, $prefix) = @_ ;

    # use Data::Dump qw{pp} ;
    # print STDERR "eval ", pp([$name, $varsrc]), "\n" ;
    my %vars ;

    $prefix ||= $varsrc?'el:':'eg:' ;
    my $refexpr ;
    my $pre ;
    my $post ;
    $refexpr = $name ;
    my $ref = eval ($refexpr) ;
    if ($@)
        {
        $vars{'ERROR'} = [$@] ;
        }
    #print STDERR "name=$name ref=$ref refref=", ref ($ref), "reftype=", reftype ($ref), "\n", pp($ref), "\n" ;
    if (ref ($ref) eq 'REF')
        {
        $ref = $$ref ;
        #print STDERR "deref ----> ref val=$refexpr ref=$ref refref=", ref ($ref), "reftype=", reftype ($ref), "\n" ;
        $pre = '${' ;
        $post = '}' ;
        }
    if (reftype ($ref) eq 'ARRAY')
        {
        my $n = 0 ;
        foreach my $entry (@$ref)
            {
            $vars{"$n"} = [\$entry, $prefix . $pre . '(' . $refexpr . ')' . $post . '->[' . $n . ']' ] ;
            $n++ ;
            }    
        }
    elsif (reftype ($ref) eq 'HASH')
        {
        my $iterator = Hash::SafeKeys::save_iterator_state($ref);
        foreach my $entry (sort keys %$ref)
            {
            $vars{"$entry"} = [\$ref -> {$entry}, $prefix . $pre . '(' . $refexpr . ')' . $post . "->{'" . $entry . "'}" ] ;
            }    
        Hash::SafeKeys::restore_iterator_state($ref, $iterator);
        }
    else
        {
        $vars{'$'} = [$ref] ;
        }

    return \%vars ;
    }

# ---------------------------------------------------------------------------

sub get_arguments 
    {
    my ($self, $frame) = @_ ;

    my $vars  ;
    my %varsrc ;
    eval
        {
        my @args = _get_caller_args ($frame+2) ;
        $varsrc{"\@_"} =    [\@args, "ea:\$varsrc->{'\@_'}[0]"] ;
        $varsrc{"\@ARGV"} = [\@main::ARGV, 'eg:\\@main::ARGV'] ;
        } ;
    $self -> logger ($@) if ($@) ;
    return (\%varsrc) ;
    }

# ---------------------------------------------------------------------------

sub get_locals 
    {
    my ($self, $frame) = @_ ;

    my $vars  ;
    my %varsrc ;
    eval
        {
        $vars = PadWalker::peek_my ($frame) ;
        foreach my $var (keys %$vars)
            {
            $varsrc{$var} = 
                [
                $vars->{$var},
                "el:\$varsrc->{'$var'}"    
                ] ;
            }
        } ;
    $self -> logger ($@) if ($@) ;
    return (\%varsrc, $vars) ;
    }

# ---------------------------------------------------------------------------

sub _get_caller_args
    {
    my ($caller) = @_ ;

    local @DB::args ;

    my @caller_args ;
        {
        package DB;

        my @call_info = caller ($caller) ;
        #use Data::Dump qw{pp} ;
        #print STDERR "db::args after caller $caller ", pp(\@DB::args), "\n" ;
        @caller_args = @DB::args ;
        }

    return @caller_args ;
    }

# ---------------------------------------------------------------------------

sub _eval_replace 
    {
    my ($___di_vars, $___di_sigil, $___di_var, $___di_suffix, $___di_frame) = @_ ;

    #print STDERR "sigil = $___di_sigil var = $___di_var suffix = $___di_suffix\n" ;

    if ($___di_var eq '_')
        {
        my @args = _get_caller_args ($___di_frame + 3) ;
        $___di_vars -> {'@_'} = \@args ;
        }
    #use Data::Dump qw{pp} ;
    #print STDERR "vars ", pp ($___di_vars),"\n" ;
    if ($___di_suffix)
        {
        return "\$___di_vars->{'\%$___di_var'}{" if ($___di_suffix eq '{' && exists $___di_vars->{"\%$___di_var"}) ;
        return "\$___di_vars->{'\@$___di_var'}[" if (exists $___di_vars->{"\@$___di_var"});
        }
    else
        {
        return "\$\#\{\$___di_vars->{'\@$1'}}" if (($___di_var =~ /^#(.+)/) && exists $___di_vars->{"\@$1"}) ;        
        #print STDERR "v = $___di_var  1 = $1\n" ;
        return "$___di_sigil\{\$___di_vars->{'$___di_sigil$___di_var'}}" if (exists $___di_vars->{"$___di_sigil$___di_var"}) ;        
        }

    return "$___di_sigil$___di_var$___di_suffix" ;
    }

# ---------------------------------------------------------------------------

sub get_eval_result 
    {
    my ($self, $frame, $package, $expression) = @_;
 
    my $___di_vars = PadWalker::peek_my ($frame) ;
 
    $expression =~ s/([\%\@\$])(#?\w+)\s*([\[\{])?/_eval_replace($___di_vars, $1, $2, $3, $frame)/eg ;

    my $code = "package $package ; no strict ; $expression";
    my %vars ;
    #print STDERR "frame=$frame code = $code\n" ;


    my @result = eval $code;
    if ($@)
        {
        $vars{'ERROR'} = [$@] ;
        }
    else
        {
        if (@result < 2)
            {
            if (ref ($result[0]) eq 'REF')
                {
                push @evalresult, $result[0] ;    
                }
            else
                {
                push @evalresult, \$result[0] ;    
                }
            }
        elsif ($expression =~ /^\s*\\?\s*\%/)
            {
            push @evalresult, { @result } ;    
            }    
        else
            {
            push @evalresult, \@result ;    
            }
        $vars{'eval'} = [$evalresult[-1], 'eg:$Perl::LanguageServer::DebuggerInterface::evalresult[' . $#evalresult . ']'] ;
        }
    
    return \%vars ;
    }

# ---------------------------------------------------------------------------

 sub get_scalar 
    {
    my $ret = eval
        {
        my ($self, $val) = @_ ;

        return 'undef' if (!defined ($val)) ;
        my $obj = '' ;
        $obj = blessed ($val) . ' ' if (blessed ($val)) ;
        return $obj . '[..]' if (ref ($val) eq 'ARRAY') ;
        return $obj . '{..}' if (ref ($val) eq 'HASH') ;
        my $isnum = looks_like_number ($val);
        $obj . ($isnum?$val:"'$val'") ;
        } ;
    return $@ if ($@) ;
    return $ret ;
    }

# ---------------------------------------------------------------------------

sub get_vars 
    {
    my ($self, $varsrc, $vars, $array) = @_ ;
    
    foreach my $k (sort { $array?$a <=> $b:$a cmp $b } keys %$varsrc)
        {
        my $key = $k ;
        my $val = $varsrc -> {$k}[0] ;
        my $ref = $varsrc -> {$k}[1] ;
        $key =~ s/([\0-\x1f])/'^'.chr(ord($1)+0x40)/eg ;
        #print STDERR "k=$k val=$val ref=$ref refref=", ref ($val), "reftype=", reftype ($ref), "\n" ;

        if (ref ($val) eq 'REF')
            {
            $val = $$val ;
            #print STDERR "deref ----> ref val=$val ref=$ref refref=", ref ($val), "reftype=", reftype ($ref), "\n" ;
            }
        my $obj = '' ;
        $obj = blessed ($val) . ' ' if (blessed ($val)) ;

        if (reftype ($val) eq 'SCALAR') 
            {
            push @$vars,
                {
                name  => $key,
                value => $obj . $self -> get_scalar ($$val),
                type  => 'Scalar',
                } ;
            }

        if (reftype ($val) eq 'ARRAY') 
            {
            my $display = $obj . '[' ;
            my $n       = 1 ;
            foreach (@$val)
                {
                $display .= ',' if ($n > 1) ;
                $display .= $self -> get_scalar ($_) ;
                if ($n++ >= $max_display)
                    {
                    $display .= ',...' ;
                    last ;    
                    }
                }
            $display .= ']' ;
            
            push @$vars,
                {
                name  => $key,
                value => $display,
                type  => 'Array',
                var_ref => $ref,
                indexedVariables => scalar (@$val),
                } ;
            }

        if (reftype ($val) eq 'HASH') 
            {
            my $display = $obj . '{' ;
            my $n       = 1 ;
            my $iterator = Hash::SafeKeys::save_iterator_state($val);
            foreach (sort keys %$val)
                {
                $display .= ',' if ($n > 1) ;
                $display .= "$_=>" . $self -> get_scalar ($val->{$_}) ;
                if ($n++ >= $max_display / 2)
                    {
                    $display .= ',...' ;
                    last ;    
                    }
                }
            $display .= '}' ;

            push @$vars,
                {
                name  => $key,
                value => $display,
                type  => 'Hash',
                var_ref => $ref,
                namedVariables => scalar (keys %$val),
                } ;
            Hash::SafeKeys::restore_iterator_state($val, $iterator);
            }

        if ($key =~ /^Handle/) 
            {
            push @$vars,
                {
                name => $key,
                value => $$val,
                type  => 'Filehandle',
                } ;
            }
        }
    }

# ---------------------------------------------------------------------------

sub get_varsrc
    {
    my ($class, $frame_ref, $package, $type) = @_ ;

    my @vars ;
    my $varsrc ;
    if ($type eq 'l')
        {
        ($varsrc) = $class -> get_locals($frame_ref+3) ;
        }
    elsif ($type eq 'a')
        {
        ($varsrc) = $class -> get_arguments($frame_ref+3) ;
        }
    elsif ($type eq 'g')
        {
        $varsrc = $class -> get_globals($package) ;
        }
    elsif ($type eq 's')
        {
        $varsrc = $class -> get_globals() ;
        }
    elsif ($type =~ /^eg:(.+)/)
        {
        $varsrc = $class -> get_var_eval ($1) ;
        }
    elsif ($type =~ /^el:(.+)/)
        {
        my $name = $1 ;
        my ($dummy, $varlocal) = $class -> get_locals($frame_ref+3) ;
        $varsrc = $class -> get_var_eval ($name, $varlocal) ;
        }
    elsif ($type =~ /^ea:(.+)/)
        {
        my $name = $1 ;
        my ($args, $varlocal) = $class -> get_arguments($frame_ref+3) ;
        $varsrc = $class -> get_var_eval ($name, $args, 'ea:') ;
        }

    use Data::Dump qw{pp} ;
    #print STDERR "vars ", pp ($varsrc),"\n" ;
    return $varsrc ;
    }

# ---------------------------------------------------------------------------

sub req_vars
    {
    my ($class, $params, $recurse) = @_ ;

    my $thread_ref  = $params -> {thread_ref} ;
    my $tid = defined ($Coro::current)?$Coro::current+0:1 ;
    if ($thread_ref != $tid && !$recurse && ($params -> {type} !~ /^eg:/))
        {
        my $coro  ;
        $coro = $class -> find_coro ($thread_ref) ;
        return { variables => [] } if (!$coro) ;
        my $ret ;
        $coro -> call (sub {
            $ret = $class -> req_vars ($params, $recurse + 1) ;
            }) ;
        return $ret ;
        }

    my $frame_ref   = $params -> {frame_ref} - $recurse ;
    my $package     = $params -> {'package'} ;
    my $type        = $params -> {type} ;
    my $filter      = $params -> {filter} ;
    my @vars ;

    my $varsrc = $class -> get_varsrc ($frame_ref, $package, $type) ;

    eval
        {
        $class -> get_vars ($varsrc, \@vars, $filter) ;
        } ;
    $class -> logger ($@) if ($@) ;

    return { variables => \@vars } ;
    }

# ---------------------------------------------------------------------------

sub _set_var_expr
    {
    my ($class, $type, $setvar, $expr_ref) = @_ ;

    if (!$type)
        {
        if ($setvar)
            {
            $$expr_ref = $setvar . '=' . $$expr_ref ;
            }    
        return ;
        }

    my $refexpr ;
    if ($type =~ /^eg:(.+)/)
        {
        $refexpr = $1 ;
        my $ref = eval ($refexpr) ;
        return      
            {
            name => "ERROR",
            value => $@,
            } if ($@) ;
        if (reftype ($ref) eq 'ARRAY')
            {
            $refexpr .= '[' . $setvar . ']' ;
            } 
        elsif (reftype ($ref) eq 'HASH')
            {
            $refexpr .= '{' . $setvar . '}' ;
            } 
        elsif (reftype ($ref) eq 'SCALAR')
            {
            $refexpr = '${' . $refexpr . '}' ;
            }
        else
            {
            return      
                {
                name => "ERROR",
                value => "Cannot set variable if reference is of type " . reftype ($ref) ,
                }  ;
            } 
        }
    else
        {
        return      
            {
            name => "ERROR",
            value => "Invalid type: $type",
            }  ;
        }

    $$expr_ref = $refexpr . '=' . $$expr_ref ;

    return ;
    }


# ---------------------------------------------------------------------------

sub req_setvar
    {
    my ($class, $params) = @_ ;

    my $thread_ref  = $params -> {thread_ref} ;
    my $tid = defined ($Coro::current)?$Coro::current+0:1 ;
    return undef if ($thread_ref != $tid) ;

    my $frame_ref   = $params -> {frame_ref} ;
    my $package     = $params -> {'package'} ;
    my $expression  = $params -> {'expression'} ;
    my $setvar      = $params -> {'setvar'} ;
    my $type        = $params -> {'type'} ;
    my @vars ;
    my $resultsrc ;
    my $varref ;
    my $varsrc = $class -> get_varsrc ($frame_ref, $package, $type) ;
    if (!exists $varsrc -> {$setvar})
        {
        return      
            {
            name => "ERROR",
            value => "unknown variable: $setvar",
            } ;
        }
    $varref = $varsrc -> {$setvar}[0] ;
    eval
        {
        $resultsrc = $class -> get_eval_result ($frame_ref+2, $package, $expression) ;

        $$varref = ${$resultsrc -> {eval}[0]} ;
        } ;
    return      
        {
        name => "ERROR",
        value => $@,
        } if ($@) ;

    return
        {
        name => $setvar,
        value => "$$varref",
        } ;
    }

# ---------------------------------------------------------------------------

sub req_evaluate
    {
    my ($class, $params, $recurse) = @_ ;

    return undef if ($params -> {'context'} eq 'hover' && ($params -> {'expression'} !~ /^\s*\\?[\$\@\%]/)) ;

    my $thread_ref  = $params -> {thread_ref} ;
    my $tid = defined ($Coro::current)?$Coro::current+0:1 ;
    if ($thread_ref != $tid && !$recurse)
        {
        my $coro  ;
        $coro = $class -> find_coro ($thread_ref) ;
        return undef if (!$coro) ;
        my $ret ;
        $coro -> call (sub {
            $ret = $class -> req_evaluate ($params, $recurse + 1) ;
            }) ;
        return $ret ;
        }

    my $frame_ref   = $params -> {frame_ref} - $recurse ;
    my $package     = $params -> {'package'} ;
    my $expression  = $params -> {'expression'} ;
    my @vars ;
    my $varsrc ;

    eval
        {
        $varsrc = $class -> get_eval_result ($frame_ref+2, $package, $expression) ;

        $class -> get_vars ($varsrc, \@vars) ;
        } ;
    return      
        {
        name => "ERROR",
        value => $@,
        } if ($@) ;

    return $vars[0] ;
    }

# ---------------------------------------------------------------------------

sub req_threads
    {
    my @threads ;

    if (defined &Coro::State::list)
        {
        foreach my $coro (Coro::State::list()) 
            {
            push @threads,
                {
                name         => $coro->debug_desc,
                thread_ref   => $coro+0,
                } ;
            }    
        }
    else
        {
        @threads = { thread_ref => 1, name => 'single'} ;    
        }
    
    return { threads => \@threads } ;
    }

# ---------------------------------------------------------------------------


sub find_coro 
    {
    my ($class, $pid) = @_;
 
    return if (!defined &Coro::State::list) ;
    
    if (my ($coro) = grep ($_ == $pid, Coro::State::list())) 
        {
        return $coro ;
        } 
    else 
        {
        $class -> logger ("$pid: no such coroutine\n") ;
        }
    return ;
    }

# ---------------------------------------------------------------------------

sub req_stack
    {
    my ($class, $params, $recurse) = @_ ;

    my $thread_ref   = $params -> {thread_ref} ;
    my $tid = defined ($Coro::current)?$Coro::current+0:1 ;
    if ($thread_ref != $tid && !$recurse)
        {
        my $coro  ;
        $coro = $class -> find_coro ($thread_ref) ;
        return { stackFrames => [] } if (!$coro) ;
        my $ret ;
        $coro -> call (sub {
            $ret = $class -> req_stack ($params, 1) ;
            }) ;
        return $ret ;
        }

    my $levels       = $params -> {levels} || 999 ;
    my $start_frame  = $params -> {start} || 0 ;
    $start_frame += 3 ;
    my @stack ;
        {
        package DB;

        my $i = 0  ; 

        my @frames ;
        while ((my @call_info = caller($i++)))
            {
            my $sub = $call_info[3] ;
            push @frames, \@call_info ;
            $frames[-2][3] = $sub if (@frames > 1);
            }
        $frames[-1][3] = '<main>' if (@frames > 0);

        my $n = @frames + 1 ;
        $i = $n ;
        my $j = -1 ;
        while (my $frame = shift @frames)
            {
            $i-- ;
            $j++ ;
            next if ($start_frame-- > 0) ;
            last if ($levels-- <= 0) ;    
            
            my ($package, $filename, $line, $subroutine, $hasargs) = @$frame ;
            
            my $sub_name = $subroutine ;
            $sub_name = $1 if ($sub_name =~ /.+::(.+?)$/) ;

            my $frame =
                {
                frame_ref   => $j,
                name        => $sub_name,
                source      => { path => $filename },
                line        => $line,
                column      => 1,
                #moduleId    => $package,
                'package'   => $package,
                } ;
            $j-- if ($sub_name eq '(eval)') ;    
            push @stack, $frame ;
            }
        }

    return { stackFrames => \@stack } ;
    }

# ---------------------------------------------------------------------------

sub _set_breakpoint 
    {
    my ($class, $location, $condition) = @_ ;

    $condition ||= '1';
    my $subname ;
    my $filename ;
    ($location, $subname, $filename) = DB::_find_subline($location) if ($location =~ /\D/);

    return (0, "Subroutine not found.") unless $location ;
    return (0) if (!$location) ;
    
    local *dbline = "::_<$filename" if ($filename) ;
    for (my $line = $location; $line <= $location + 10 && $location < @dbline; $line++)
        {
        if ($dbline[$line] != 0)
            {
            $dbline{$line+0} =~ s/^[^\0]*/$condition/;
            return (1, undef, $line, $filename) ;    
            }
        }

    return (0, "Line $location for sub $subname is not breakable.") if ($subname) ;
    return (0, "Line $location is not breakable.") ;
    }

# ---------------------------------------------------------------------------
# abs path no dereference
# copied from package Cwd::Ext and added directory argument
sub abs_path_nd {   
   my $abs_path = shift;
   my $dir      = shift ;
   return $abs_path if $abs_path=~m{^/$};
    
   unless( $abs_path=~/^\// ){
      if ($dir) {
          $abs_path = $dir."/$abs_path";
      }
      else {
          require Cwd;
          $abs_path = Cwd::cwd()."/$abs_path";
      }
   }
     
    my @elems = split m{/}, $abs_path;
    my $ptr = 1;
    while($ptr <= $#elems){
        if($elems[$ptr] eq ''      ){
            splice @elems, $ptr, 1;
        }
 
        elsif($elems[$ptr] eq '.'  ){
            splice @elems, $ptr, 1;
        }
 
        elsif($elems[$ptr] eq '..' ){
            if($ptr < 2){
                splice @elems, $ptr, 1;
            }
            else {
                $ptr--;
                splice @elems, $ptr, 2;
            }
        }
        else {
            $ptr++;
        }
    }
 
    $#elems ? join q{/}, @elems : q{/};
}

# ---------------------------------------------------------------------------

sub req_breakpoint
    {
    my ($class, $params) = @_ ;

    my $breakpoints  = $params -> {breakpoints} ;
    my $filename     = $params -> {filename} ;
    my $real_filename = $params -> {dbg_filename} || $filename ;

    Class::Refresh -> refresh if ($refresh) ;

    if ($filename)
        {
        my %seen ;
        while (!defined $main::{'_<' . $real_filename} && -l $real_filename)
            {
            my $dir = File::Basename::dirname ($real_filename) ;
            $real_filename = readlink ($real_filename) ;
            last if (!$real_filename) ;
            $real_filename = abs_path_nd ($real_filename, $dir) ;
            last if ($seen{$real_filename}++) ;
            } 

        if (!defined $main::{'_<' . $real_filename})
            {
            $postponed_breakpoints{$filename} = $breakpoints ;
            foreach my $bp (@$breakpoints)
                {
                $bp -> [6] = $breakpoint_id++ ; 
                }
            return { breakpoints => $breakpoints }
            }
        }    
     
    local *dbline = "::_<$real_filename" if ($real_filename) ;
    if ($real_filename)
        {
        # Switch the magical hash temporarily.
        local *DB::dbline = "::_<$real_filename";
        $class -> clr_breaks () ;
        $class -> clr_actions () ;
        }
    
    foreach my $bp (@$breakpoints)
        {
        my $line      = $bp -> [0] ;
        my $condition = $bp -> [1] ;
        ($bp -> [2], $bp -> [3], $bp -> [4], $bp -> [5]) = $class -> _set_breakpoint ($line, $condition) ;
        $bp -> [5] = $filename if ($filename) ;
        }
    return { breakpoints_set => 1, breakpoints => $breakpoints, ($filename ne $real_filename?(real_filename => $real_filename, req_filename => $filename):()) };
    }

# ---------------------------------------------------------------------------

package DB
    {
    use vars qw{@dbline %dbline $dbline} ;

    sub postponed
        {
        my ($arg) = @_ ;

        return if (!$loaded) ;

        # If this is a subroutine...
        if (ref(\$arg) ne 'GLOB') 
            {
            return ;
            }
        # Not a subroutine. Deal with the file.
        local *dbline = $arg ;
        my $filename = $dbline; 
        my %seen ;
        my $pp_filename = $filename ;
        while (!exists $postponed_breakpoints{$pp_filename} && -l $pp_filename)
            {
            my $dir = File::Basename::dirname ($pp_filename) ;
            $pp_filename = readlink ($pp_filename) ;
            last if (!$pp_filename) ;
            $pp_filename = Perl::LanguageServer::DebuggerInterface::abs_path_nd ($pp_filename, $dir) ;
            last if ($seen{$pp_filename}++) ;
            } 

        #Perl::LanguageServer::DebuggerInterface -> _send ({ command => 'di_loadedfile', arguments => { session_id => $session, reason => 'new', source => { path => $filename}}}) ;

        if (exists $postponed_breakpoints{$pp_filename})
            {
            my $ret = Perl::LanguageServer::DebuggerInterface -> req_breakpoint ({ breakpoints => $postponed_breakpoints{$pp_filename}, filename => $pp_filename, dbg_filename => $filename }) ;
            if ($ret -> {breakpoints_set})
                {
                delete $postponed_breakpoints{$pp_filename} ;
                Perl::LanguageServer::DebuggerInterface -> _send ({ command => 'di_breakpoints', 
                                                    arguments => { session_id => $session, %$ret}}) ;
                }
            }
        }
    }

# ---------------------------------------------------------------------------

sub req_can_break
    {
    my ($class, $params) = @_ ;

    my $line        = $params -> {line} ;
    my $end_line    = $params -> {end_line} || $line ;
    my $filename    = $params -> {filename} ;
    my $real_filename = $filename ;

    my %seen ;
    while (!defined $main::{'_<' . $real_filename} && -l $real_filename)
        {
        my $dir = File::Basename::dirname ($real_filename) ;
        $real_filename = readlink ($real_filename) ;
        last if (!$real_filename) ;
        $real_filename = abs_path_nd ($real_filename, $dir) ;
        last if ($seen{$real_filename}++) ;
        } 

    return { breakpoints => [] } if (!defined $main::{'_<' . $real_filename}) ;

    Class::Refresh -> refresh if ($refresh) ;

    # Switch the magical hash temporarily.
    local *dbline = "::_<$real_filename";

    my @bp ;
    for (my $i = $line; $i <= $end_line; $i++)
        {
        if ($dbline[$line] != 0)
            {
            push @bp, { line => $line } ;    
            }        
        }
        
    return { breakpoints => \@bp };
    }

    
# ---------------------------------------------------------------------------

sub req_continue
    {
    my ($class, $params) = @_ ;

    Class::Refresh -> refresh if ($refresh) ;

    @evalresult = () ;
    $class -> cont ;

    return ;
    }

# ---------------------------------------------------------------------------

sub req_step_in
    {
    my ($class, $params) = @_ ;

    Class::Refresh -> refresh if ($refresh) ;

    @evalresult = () ;
    $class -> step ;

    return ;
    }

# ---------------------------------------------------------------------------

sub req_step_out
    {
    my ($class, $params) = @_ ;

    Class::Refresh -> refresh if ($refresh) ;

    @evalresult = () ;
    $class -> ret (2) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub req_next
    {
    my ($class, $params) = @_ ;

    Class::Refresh -> refresh if ($refresh) ;

    @evalresult = () ;
    $class -> next ;

    return ;
    }


# ---------------------------------------------------------------------------

sub _send
    {
    my ($class, $result) = @_ ;

    $result -> {type} = 'dbgint' ;

    my $outdata = $json -> encode ($result) ;
    use bytes ;
    my $len  = length($outdata) ;
    my $wrdata = "Content-Length: $len\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n$outdata" ;
    $socket -> syswrite ($wrdata) ;
    if ($debug)
        {
        $wrdata =~ s/\r//g ;
        $class -> logger ($wrdata, "\n") ;
        }
    }


# ---------------------------------------------------------------------------

sub _recv
    {
    my ($class) = @_ ;

    $class -> logger ("wait for input\n") if ($debug) ;

    my $line ;
    my $cnt ;
    my $buffer ;
    my $data ;
    my %header ;
    header:
    while (1)
        {
        $cnt = sysread ($socket, $buffer, 8192, length ($buffer)) ;
        die "read_error reading headers ($!)" if ($cnt < 0) ;
        return if ($cnt == 0) ;

        while ($buffer =~ s/^(.*?)\R//)
            {
            $line = $1 ;    
            $class -> logger ("line=<$line>\n") if ($debug) ;
            last header if ($line eq '') ;
            $header{$1} = $2 if ($line =~ /(.+?):\s*(.+)/) ;
            }
        }

    my $len = $header{'Content-Length'} ;
    my $data ;
    $class -> logger ("len=$len len buffer=", length ($buffer), "\n")  if ($debug) ;
    while ($len > length ($buffer)) 
        {
        $cnt = sysread ($socket, $buffer, $len - length ($buffer), length ($buffer)) ;
        die "read_error reading data ($!)" if ($cnt < 0) ;
        return if ($cnt == 0) ;
        }
    if ($len == length ($buffer)) 
        {
        $data = $buffer ;
        $buffer = '' ;
        }
    elsif ($len < length ($buffer)) 
        {
        $data   = substr ($buffer, 0, $len) ;
        $buffer = substr ($buffer, $len) ;
        }
    else
        {
        die "to few data bytes" ;
        }    
    $class -> logger ("read data=", $data, "\n") if ($debug) ;
    $class -> logger ("read header=", "%header", "\n") if ($debug) ;

    my $cmddata = $json -> decode ($data) ;
    my $cmd = 'req_' . $cmddata -> {command} ;
    if ($class -> can ($cmd))
        {
        my $result = $class -> $cmd ($cmddata) ;
        $class -> _send ({ command => 'di_response', seq => $cmddata -> {seq}, arguments => $result}) ;
        return ;
        }
    die "unknown cmd $cmd" ;    
    }


# ---------------------------------------------------------------------------

sub awaken
    {
    my ($class) = @_ ;
    $class -> logger ("enter awaken\n") if ($debug) ;

    $break_reason = 'pause' ;
    #$class -> _send ({ command => 'di_break', arguments => { session_id => $session, reason => 'pause'}}) ;
    }

# ---------------------------------------------------------------------------

sub init
    {
    my ($class) = @_ ;

    $class -> logger ("enter init\n") if ($debug) ;

    $refresh = ($ENV{PLSDI_OPTIONS} =~ /reload_modules/)?1:0 ;
    if ($refresh) 
        {
        require Class::Refresh ;  
        Class::Refresh -> refresh ;
        }

    my $remote ;
    my $port ;
    ($remote, $port) = split /:/, $ENV{PLSDI_REMOTE} ;

    $socket = IO::Socket::INET->new(PeerAddr => $remote,
                                    PeerPort => $port,
                                    Proto    => 'tcp') 
            or die "Cannot connect to $remote:$port ($!)";

    $class -> ready (1) ;
    }

# ---------------------------------------------------------------------------

sub stop
    {
    my ($class) = @_ ;
    $class -> logger ("enter stop @_\n") if ($debug) ;

    }

# ---------------------------------------------------------------------------

sub idle
    {
    my ($class) = @_ ;
    $class -> logger ("enter idle @_\n") if ($debug) ;

    my $cmd = $class -> _recv () ;

    }

# ---------------------------------------------------------------------------

sub cleanup
    {
    my ($class) = @_ ;
    $class -> logger ("enter cleanup @_\n") if ($debug) ;

    }

# ---------------------------------------------------------------------------

sub output
    {
    my ($class) = @_ ;
    $class -> logger ("enter output @_\n") if ($debug) ;

    }

# ---------------------------------------------------------------------------

sub showfile
    {
    my ($class, $filename, $line) = @_ ;
    $class -> logger ("enter showfile @_\n") if ($debug) ;

    #$class -> _send ({ command => 'di_showfile', arguments => { session_id => $session, reason => 'new', source => { path => $filename}}}) ;
    }

# ---------------------------------------------------------------------------

sub evalcode
    {
    my ($class) = @_ ;
    $class -> logger ("enter evalcode @_\n") if ($debug) ;

    }

# ---------------------------------------------------------------------------

sub cprestop
    {
    my ($class) = @_ ;
    $class -> logger ("enter cprestop @_\n") if ($debug) ;

    @evalresult = () ;
    my $tid = defined ($Coro::current)?$Coro::current+0:1 ;
    $class -> _send ({ command => 'di_break', 
                       arguments => 
                        { 
                        thread_ref => $tid, 
                        session_id => $session,
                        ($break_reason?(reason => $break_reason):()),
                        }}) ;
    $break_reason = undef ;                        
    }

# ---------------------------------------------------------------------------

sub cpoststop
    {
    my ($class) = @_ ;
    $class -> logger ("enter cpoststop @_\n") if ($debug) ;
    }


# ---------------------------------------------------------------------------

$loaded = 1 ;

1 ;
