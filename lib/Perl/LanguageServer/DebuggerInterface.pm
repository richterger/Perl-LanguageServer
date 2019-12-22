package Perl::LanguageServer::DebuggerInterface ;

use DB;

our @ISA = qw(DB); 

use strict ;

use IO::Socket ;
use JSON ;
use PadWalker ;
use Scalar::Util qw{blessed reftype looks_like_number};
use Data::Dump qw{pp} ;
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
    my ($self, $name, $varsrc) = @_ ;

    my %vars ;

    my $prefix = $varsrc?'el:':'eg:' ;
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
        foreach my $entry (sort keys %$ref)
            {
            $vars{"$entry"} = [\$ref -> {$entry}, $prefix . $pre . '(' . $refexpr . ')' . $post . "->{'" . $entry . "'}" ] ;
            }    
        }
    else
        {
        $vars{'$'} = [$ref] ;
        }

    return \%vars ;
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
    logger ($@) if ($@) ;
    return (\%varsrc, $vars) ;
    }

# ---------------------------------------------------------------------------

sub _eval_replace 
    {
    my ($___di_vars, $___di_sigil, $___di_var, $___di_suffix) = @_ ;

    if ($___di_suffix)
        {
        return "\$___di_vars->{'\%$___di_var'}{" if ($___di_suffix eq '{' && exists $___di_vars->{"\%$___di_var"}) ;
        return "\$___di_vars->{'\@$___di_var'}[" if (exists $___di_vars->{"\@$___di_var"});
        }
    else
        {
        return "$___di_sigil\{\$___di_vars->{'$___di_sigil$___di_var'}}" if (exists $___di_vars->{"$___di_sigil$___di_var"}) ;        
        }

    return "$___di_sigil$___di_var$___di_suffix" ;
    }

# ---------------------------------------------------------------------------

sub get_eval_result 
    {
    my ($self, $frame, $package, $expression) = @_;
 
    my $___di_vars = PadWalker::peek_my ($frame) ;
 
    $expression =~ s/([\%\@\$])(\w+)\s*([\[\{])?/_eval_replace($___di_vars, $1, $2, $3)/eg ;

    my $code = "package $package ; no strict ; $expression";
    my %vars ;
    #print STDERR "code = $code\n" ;

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
    my ($self, $val) = @_ ;

    return 'undef' if (!defined ($val)) ;
    my $obj = '' ;
    $obj = blessed ($val) . ' ' if (blessed ($val)) ;
    return $obj . '[..]' if (ref ($val) eq 'ARRAY') ;
    return $obj . '{..}' if (ref ($val) eq 'HASH') ;
    my $isnum = looks_like_number ($val);
    return $obj . ($isnum?$val:"'$val'") ;
    }

# ---------------------------------------------------------------------------

sub get_vars 
    {
    my ($self, $varsrc, $vars) = @_ ;
    
    foreach my $k (sort keys %$varsrc)
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

    return $varsrc ;
    }

# ---------------------------------------------------------------------------

sub req_vars
    {
    my ($class, $params) = @_ ;

    my $thread_ref  = $params -> {thread_ref} ;
    my $tid = defined ($Coro::current)?$Coro::current+0:1 ;
    return { variables => [] } if ($thread_ref != $tid) ;

    my $frame_ref   = $params -> {frame_ref} ;
    my $package     = $params -> {'package'} ;
    my $type        = $params -> {type} ;
    my @vars ;

    my $varsrc = $class -> get_varsrc ($frame_ref, $package, $type) ;

    $class -> get_vars ($varsrc, \@vars) ;

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
    my ($class, $params) = @_ ;

    my $thread_ref  = $params -> {thread_ref} ;
    my $tid = defined ($Coro::current)?$Coro::current+0:1 ;
    return undef if ($thread_ref != $tid) ;

    my $frame_ref   = $params -> {frame_ref} ;
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
    $location = DB::_find_subline($location) if ($location =~ /\D/);

    return (0, "Subroutine not found.") unless $location ;
    return (0) if (!$location) ;
    
    for (my $line = $location; $line <= $location + 10 && $location < @dbline; $line++)
        {
        if ($dbline[$line] != 0)
            {
            $dbline{$line+0} =~ s/^[^\0]*/$condition/;
            return (1, undef, $line) ;    
            }
        }

    return (0, "Line $location is not breakable.") ;
    }

# ---------------------------------------------------------------------------

sub req_breakpoint
    {
    my ($class, $params) = @_ ;

    my $breakpoints  = $params -> {breakpoints} ;
    my $filename     = $params -> {filename} ;

    if ($filename && !defined $main::{'_<' . $filename})
        {
        $postponed_breakpoints{$filename} = $breakpoints ;
        foreach my $bp (@$breakpoints)
            {
            $bp -> [6] = $breakpoint_id++ ; 
            }
        return { breakpoints => $breakpoints }
        }
    
     
    local *dbline = "::_<$filename" if ($filename) ;
    if ($filename)
        {
        # Switch the magical hash temporarily.
        local *DB::dbline = "::_<$filename";
        $class -> clr_breaks () ;
        }
    
    foreach my $bp (@$breakpoints)
        {
        my $line      = $bp -> [0] ;
        my $condition = $bp -> [1] ;
        ($bp -> [2], $bp -> [3], $bp -> [4]) = $class -> _set_breakpoint ($line, $condition, $filename) ;
        $bp -> [5] = $filename ;
        }

    return { breakpoints_set => 1, breakpoints => $breakpoints };
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

        #Perl::LanguageServer::DebuggerInterface -> _send ({ command => 'di_loadedfile', arguments => { session_id => $session, reason => 'new', source => { path => $filename}}}) ;

        if (exists $postponed_breakpoints{$filename})
            {
            my $ret = Perl::LanguageServer::DebuggerInterface -> req_breakpoint ({ breakpoints => $postponed_breakpoints{$filename}, filename => $filename }) ;
            if ($ret -> {breakpoints_set})
                {
                delete $postponed_breakpoints{$filename} ;
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

    return { breakpoints => [] } if ($filename && !defined $main::{'_<' . $filename}) ;

    # Switch the magical hash temporarily.
    local *dbline = "::_<$filename";

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

    @evalresult = () ;
    $class -> cont ;

    return ;
    }

# ---------------------------------------------------------------------------

sub req_step_in
    {
    my ($class, $params) = @_ ;

    @evalresult = () ;
    $class -> step ;

    return ;
    }

# ---------------------------------------------------------------------------

sub req_step_out
    {
    my ($class, $params) = @_ ;

    @evalresult = () ;
    $class -> ret (2) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub req_next
    {
    my ($class, $params) = @_ ;

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
    die "unknow cmd $cmd" ;    
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

    my ($remote, $port) = split /:/, $ENV{PLSDI_REMOTE} ;

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
