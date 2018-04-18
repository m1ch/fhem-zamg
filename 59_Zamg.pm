##############################################
# $Id: 99_Zamg.pm 2342 2015-05-06 m1ch $
package main;

use strict;
use warnings;
use HTML::TableExtract;
use Time::HiRes qw(gettimeofday);
use HttpUtils;
use Blocking;

sub Zamg_Initialize($$)
{
  my ($hash) = @_;
  
  $hash->{DefFn}   = "Zamg_Define";
  $hash->{UndefFn} = "Zamg_Undef";
  $hash->{SetFn}   = "Zamg_Set";
  $hash->{GetFn}   = "Zamg_Get";
  $hash->{AttrList}= "localicons ".
                      $readingFnAttributes;
}

sub Zamg_Define($$)
{
  my ($hash, $def) = @_;
  
  # define <name> Zamg <location> [interval]
  # define MyWeather Zamg "Steiermark,Graz Strassgang" 3600
  my @a = split("[ \t][ \t]*", $def);

  return "syntax: define <name> Zamg <location> [interval]"
    if(int(@a) < 3 && int(@a) > 4); 

  $hash->{STATE} = "Initialized";
  $hash->{fhem}{interfaces}= "temperature;humidity;wind";

  Log3 $hash, 4, "Zamg ". $hash->{NAME} . ":" . int(@a);
  
  my $name      = $a[0];
  my $location  = $a[2];
  my $interval  = 3600;
  if ( int(@a)==4 ) {
    $interval= $a[3];
  }

  $hash->{LOCATION}     = $location;
  $hash->{INTERVAL}     = $interval;
  $hash->{UNITS}        = "c"; # hardcoded to use degrees centigrade (Celsius)
  $hash->{READINGS}{current_date_time}{TIME}= TimeNow();
  $hash->{READINGS}{current_date_time}{VAL}= "none";

  Zamg_RetrieveData($hash->{NAME}, 1);

  InternalTimer(gettimeofday()+$hash->{INTERVAL}, "Zamg_GetUpdateTimer", $hash, 0);

  return undef;
}

sub Zamg_Undef($@)
{
  my ($hash, $arg) = @_;

  RemoveInternalTimer($hash);
  return undef;
}

sub Zamg_Set($@)
{
  my ($hash, @a) = @_;

  my $cmd= $a[1];

  # usage check
  if((@a == 2) && ($a[1] eq "update")) {
    RemoveInternalTimer($hash);

    Zamg_RetrieveData($hash->{NAME}, 0);
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "Zamg_set", $hash, 1);
    return undef;
  } else {
    return "Unknown argument $cmd, choose one of update";
  }
}

sub Zamg_Get($@)
{
  my ($hash, @a) = @_;

  return "argument is missing" if(int(@a) != 2);

  my $reading= $a[1];
  my $value;

  if(defined($hash->{READINGS}{$reading})) {
    $value= $hash->{READINGS}{$reading}{VAL};
  } else {
    my $rt= ""; 
    if(defined($hash->{READINGS})) {
      $rt= join(" ", sort keys %{$hash->{READINGS}});
    }   
    return "Unknown reading $reading, choose one of " . $rt;
  }

  return "$a[0] $reading => $value";
}

sub Zamg_RetrieveData($$)
{
  my ($name, $blocking) = @_;
  my $hash = $defs{$name};
 
  my $location= $hash->{LOCATION}; 
  my $units= $hash->{UNITS}; 
  my $url = "http://www.zamg.ac.at/cms/de/wetter/wetterwerte-analysen/steiermark";
  
  if ($blocking) {
    #my $response = GetFileFromURL($url, 5, undef, 0);
    my $response = HttpUtils_BlockingGet(
      {
        url        => $url,
        timeout    => 5,
      }
    );
    my %param = (hash => $hash, doTrigger => 0);
    Zamg_RetrieveDataFinished(\%param, undef, $response);
  }
  else {
    HttpUtils_NonblockingGet(
      {
          url        => $url,
          timeout    => 5,
          hash       => $hash,
          doTrigger  => 1,
          callback   => \&Zamg_RetrieveDataFinished,
      }
    );
  }
}

sub Zamg_RetrieveDataFinished($$$)
{
  my ( $param, $err, $xml ) = @_;
  my $hash = $param->{hash};
  my $doTrigger = $param->{doTrigger};
  my $name = $hash->{NAME};

  my $urlResult;
  if (defined($xml) && $xml ne "") {

    my $table_extract = HTML::TableExtract->new( headers => [qw(Ort Temp Feuchte Wind Windspitzen Niederschlagssumme Sonnenscheindauer Luftdruck)]);
    $table_extract->parse($xml);

    foreach my $ts ($table_extract->tables) {
      foreach my $row ($ts->rows) {
        if ( @$row[0] =~ m/^Graz Stra.gang/ ) {
          $urlResult->{"readings"}->{"temperature"}    = (@$row[1] =~ m/([-\d\.]+)/);
          $urlResult->{"readings"}->{"temp_c"}         = (@$row[1] =~ m/([-\d\.]+)/);
          $urlResult->{"readings"}->{"humidity"}       = (@$row[2] =~ m/([-\d\.]+)/);
          $urlResult->{"readings"}->{"wind_direction"} = "Nord";
          $urlResult->{"readings"}->{"wind_speed"}     = (@$row[3] =~ m/([\d\.]+)/);
          $urlResult->{"readings"}->{"wind_max_speed"} = (@$row[4] =~ m/([\d\.]+)/);
          $urlResult->{"readings"}->{"rain"}           = (@$row[5] =~ m/([\d\.]+)/);
          $urlResult->{"readings"}->{"sunshine"}       = (@$row[6] =~ m/([\d\.]+)/);
          $urlResult->{"readings"}->{"pressure"}       = (@$row[7] =~ m/([\d\.]+)/);
        }
      }
    }
  }

  if (exists($urlResult->{readings})) {
    readingsBeginUpdate($hash);
    while ( (my $key, my $value) = each %{$urlResult->{readings}} )
    {
      readingsBulkUpdate($hash, $key, $value);
    }
    
    my $temperature= $hash->{READINGS}{temperature}{VAL};
    my $humidity= $hash->{READINGS}{humidity}{VAL};
    my $wind= $hash->{READINGS}{wind}{VAL};
    my $val= "T: $temperature  H: $humidity  W: $wind";
    Log3 $hash, 4, "Zamg ". $hash->{NAME} . ": $val";
    readingsBulkUpdate($hash, "state", $val);
    readingsEndUpdate($hash, $doTrigger ? 1 : 0);
  }
}


1;

