package Perl::LanguageServer::DebuggerInterface ;

use DB;

our @ISA = qw(DB); 

use strict ;

use IO::Socket ;
use JSON ;
use PadWalker ;
use Data::Dump qw{pp} ;

our $max_display = 5 ;
our $debug = 1 ;
our $session = $ENV{PLSDI_SESSION} || 1 ;
our $socket ;
our $json = JSON -> new -> utf8(1) -> ascii(1) ;
our $evalresult ;


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
    $refexpr = $name ;
    my $ref = eval ($refexpr) ;
    if ($@)
        {
        $vars{'ERROR'} = [$@] ;
        }
print STDERR "name=$name ref=$ref refref=", ref ($ref), "\n", pp($ref), "\n" ;
    if (ref ($ref) eq 'ARRAY')
        {
        my $n = 0 ;
        foreach my $entry (@$ref)
            {
            $vars{"$n"} = [\$entry, $prefix . '(' . $refexpr . ')->[' . $n . ']' ] ;
            $n++ ;
            }    
        }
    elsif (ref ($ref) eq 'HASH')
        {
        foreach my $entry (sort keys %$ref)
            {
            $vars{"$entry"} = [\$ref -> {$entry}, $prefix . '(' . $refexpr . ')->{' . $entry . '}' ] ;
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

    my $vars = PadWalker::peek_my ($frame) ;
    my %varsrc ;
    foreach my $var (keys %$vars)
        {
        $varsrc{$var} = 
            [
            $vars->{$var},
            "el:\$varsrc->{'$var'}"    
            ] ;
        }
    return (\%varsrc, $vars) ;
    }

# ---------------------------------------------------------------------------

sub get_eval_result 
    {
    my ($self, $frame, $package, $expression) = @_;
 
    my $vars = PadWalker::peek_my ($frame) ;
 
    my $var_declare = "package $package ; no strict ; ";
    for my $varname (keys %$vars) 
        {
        $var_declare .= "my $varname = " . pp(${$vars->{$varname}}) . ";";
        }
    my $code = "$var_declare; $expression";
    my %vars ;
print STDERR "code = $code\n" ;

    my @result = eval $code;
    if ($@)
        {
        $vars{'ERROR'} = [$@] ;
        }
    else
        {
print STDERR pp (\@result), "\n" ;
        if (@result < 2)
            {
            $evalresult = \$result[0] ;    
            }
        elsif ($expression =~ /^\s\%/)
            {
            $evalresult = { @result } ;    
            }    
        else
            {
            $evalresult = \@result ;    
            }
        $vars{'eval'} = [$evalresult, 'eg:$Perl::LanguageServer::DebuggerInterface::evalresult']
        }
    
    return \%vars ;
    }

# ---------------------------------------------------------------------------

 sub get_scalar 
    {
    my ($self, $val) = @_ ;

    return "$val" ;
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
print STDERR "k=$k val=$val ref=$ref refref=", ref ($val), "\n" ;

        if (ref ($val) eq 'REF')
            {
            $val = $$val ;
print STDERR "ref val=$val ref=$ref refref=", ref ($val), "\n" ;
            }
        if (ref ($val) eq 'SCALAR') 
            {
            push @$vars,
                {
                name  => $key,
                value => $self -> get_scalar ($$val),
                type  => 'Scalar',
                } ;
            }

        if (ref ($val) eq 'ARRAY') 
            {
            my $display = '[' ;
            my $n       = 1 ;
            foreach (@$val)
                {
                $display .= ',' if ($n > 1) ;
                $display .= "$_" ;
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

        if (ref ($val) eq 'HASH') 
            {
            my $display = '{' ;
            my $n       = 1 ;
            foreach (sort keys %$val)
                {
                $display .= ',' if ($n > 1) ;
                $display .= "$_->$val->{$_}" ;
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

sub req_vars
    {
    my ($class, $params) = @_ ;

    my $thread_ref  = $params -> {thread_ref} ;
    my $frame_ref   = $params -> {frame_ref} ;
    my $package     = $params -> {'package'} ;
    my $type        = $params -> {type} ;
    my @vars ;
    my $varsrc ;
    if ($type eq 'l')
        {
        ($varsrc) = $class -> get_locals($frame_ref+2) ;
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
        my ($dummy, $varlocal) = $class -> get_locals($frame_ref+2) ;
        $varsrc = $class -> get_var_eval ($name, $varlocal) ;
        }

    $class -> get_vars ($varsrc, \@vars) ;
    return { variables => \@vars } ;
    }

# ---------------------------------------------------------------------------

sub req_evaluate
    {
    my ($class, $params) = @_ ;

    my $thread_ref  = $params -> {thread_ref} ;
    my $frame_ref   = $params -> {frame_ref} ;
    my $package     = $params -> {'package'} ;
    my $expression  = $params -> {'expression'} ;
    my @vars ;
    my $varsrc ;

    $varsrc = $class -> get_eval_result ($frame_ref+2, $package, $expression) ;

    $class -> get_vars ($varsrc, \@vars) ;
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

sub req_stack
    {
    my ($class, $params) = @_ ;

    my $thread_ref   = $params -> {thread_ref} ;
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
                #column      => 0,
                moduleId    => $package,
                'package'   => $package,
                } ;
            push @stack, $frame ;
            }
        }

    return { stackFrames => \@stack } ;
    }

# ---------------------------------------------------------------------------

sub req_continue
    {
    my ($class, $params) = @_ ;

    $class -> cont ;

    return ;
    }

# ---------------------------------------------------------------------------

sub req_step_in
    {
    my ($class, $params) = @_ ;

    $class -> step ;

    return ;
    }

# ---------------------------------------------------------------------------

sub req_step_out
    {
    my ($class, $params) = @_ ;

    $class -> ret (2) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub req_next
    {
    my ($class, $params) = @_ ;

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

    $class -> logger ("wait for input\n") ;

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
    $class -> logger ("read data=", $data, "\n") ;
    $class -> logger ("read header=", "%header", "\n") ;

    my $cmddata = $json -> decode ($data) ;
    my $cmd = 'req_' . $cmddata -> {command} ;
    if ($class -> can ($cmd))
        {
        my $result = $class -> $cmd ($cmddata) ;
        $class -> _send ({ command => 'di_response', arguments => $result}) ;
        return ;
        }
    die "unknow cmd $cmd" ;    
    }


# ---------------------------------------------------------------------------

sub awaken
    {
    my ($class) = @_ ;
    $class -> logger ("enter awaken\n") if ($debug) ;

    $class -> _send ({ command => 'di_break', arguments => { session_id => $session, reason => 'pause'}}) ;
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
    my ($class) = @_ ;
    $class -> logger ("enter showfile @_\n") if ($debug) ;

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

    $class -> _send ({ command => 'di_break', arguments => { session_id => $session}}) ;
    }

# ---------------------------------------------------------------------------

sub cpoststop
    {
    my ($class) = @_ ;
    $class -> logger ("enter cpoststop @_\n") if ($debug) ;

    }


# ---------------------------------------------------------------------------


1 ;
