#!/usr/local/bin/perl
use strict;
use warnings;
use Sys::Hostname;

# Martin Colello
#
# Create Solaris zone
#
# Heavy mods 08/01/2016, use shared-ip for nics

# Get hostname of global
my $hostname = hostname();
chomp($hostname);

my $uname = `uname -a`;
# Get interfaces for public and storage vlans
my $show_link_pub = `dladm show-link | egrep 'vlan 120|public0|net0'`;
my $show_link_sto = `dladm show-link | egrep 'vlan 301|storage0|net1'`;

my $ifconfig = `ifconfig -a`;
my $setpub;
my $setstor;
if ($ifconfig =~ /public0/) {
  $setpub  = 'public0';
  $setstor = 'storage0';
} else {
  $setpub  = 'ipmp0';
  $setstor = 'ipmp1';
}

$show_link_pub =~ /(\w+)/;
my $aggr_pub   = $1;
$show_link_sto =~ /(\w+)/;
my $aggr_sto   = $1;

my $localip = `nslookup $hostname`;
$localip =~ /(\d+\.\d+\.\d+\.\d+)\s+$/;
$localip = $1;

$localip =~ /(\d+\.\d+\.\d+)/;
my $test_local_ip = $1;

if ( ! $ARGV[0] ) {
  &usage;
}

my $clear = `clear`;

# Get public and private ip addresses

my $public_ip;
my $storage_ip;

my $zone    = $ARGV[0];
chomp($zone);
$zone       = lc($zone);
my $zonenfs = "$zone".'-nfs';

my $check_dns = `nslookup $zone`;
if ($check_dns =~ /SERVFAIL/) {
  print "\nCan't find ip address for $zone.\n\n";
  print "Make sure dns is updated and give it a few minutes to populate.\n\n";
  exit 1;
}
$check_dns =~ /Address: (\d+\.\d+\.\d+\.\d+)/;
if ( defined($1) ) {
  $public_ip = $1;
} else {
  print "Zone $zone not found in dns.  Please correct and retry.\n";
  exit 1;
}
chomp($public_ip);
$public_ip =~ /(\d+\.\d+\.\d+)/;
my $test_public_ip = $1;
my $default_router = "$test_public_ip".'.1';

if ( $test_local_ip ne $test_public_ip ) {
  print "New zone must be on correct subnet, exiting...\n";
  exit 1;
}

$check_dns = `nslookup $zonenfs`;
if ($check_dns =~ /SERVFAIL/) {
  print "Can't find ip address for $zonenfs.\n";
  exit 1;
}
$check_dns =~ /Address: (\d+\.\d+\.\d+\.\d+)/;
if ( defined($1) ) {
  $storage_ip = $1;
} else {
  print "Server $zonenfs not found in dns.  Please correct and retry.\n";
  exit 1;
}
chomp($storage_ip);


#Get pset information from global zone to build menu
my @psetsraw = `cat /etc/pooladm.conf | grep pset | grep -v pool | grep -v property`;
chomp(@psetsraw);

my @psets;
foreach(@psetsraw) {
  my $pset;
  my $line = $_;
  $line =~ /name="(\w+)"/;
  if ( defined($1) ) {
    $pset = $1;
    push @psets, $pset;
  }
}

@psets = sort(@psets);

# Display menu to allow pset choice
print "$clear";
print "\nPlease choose number of pset to use for this zone:\n";
my $num = 0;
foreach(@psets) {
  my $pset = $_;
  $num++;
  print "$num: $pset\n";
}
print "\n";
my $numselection = <STDIN>;
chomp($numselection);
if ( $numselection !~ /\d/) {
  print "Needed to enter a number, exiting...\n";
  exit 1;
}

if ( ($numselection > $num) or ($numselection == 0) ) {
  print "Invalid selection, exiting...\n";
  exit 1;
}

$numselection--;

my $pset = $psets[$numselection];
chomp($pset);

# Print out information so user can verify before proceeding
print "\n\n";
print "zone name    $zone\n";
print "public ip    $public_ip\n";
print "storage ip   $storage_ip\n";
print "pset         $pset\n";

print "\n";

if ( $public_ip eq $storage_ip ) {
  print "Must use different addresses for public and storage.\n";
  exit 1;
}

print "Is the information correct? (y/n)\n";
my $yesorno = <STDIN>;
chomp($yesorno);
$yesorno    = lc($yesorno);

if ( $yesorno !~ /y/ ) {
  print "Aborting all opertions...\n";
  exit 1;
}

#my $zfscheck = `zfs list`;
#if ( $zfscheck =~ /$zone/ ) {
#  print "ZFS filesystem appears to already exist, exiting.\n";
#  exit 1;
#}


&log("Creating ZFS filesystem for $zone...");
my $zoneroot;
my @zfs_list = `zfs list`;
chomp(@zfs_list);
foreach(@zfs_list){
  my $line = $_;
  if ( $line =~ /^zones/ ) {
    $zoneroot = 'zones/';
  }
  if ( $line =~ /^rpool\/zones/ ) {
    $zoneroot = 'rpool/zones/';
  }
}

$zoneroot = "$zoneroot"."$zone";
system("zfs create -o mountpoint=/zones/$zone -o compression=on -o quota=10g $zoneroot");
system("chmod 700 /zones/$zone");

&log ("Creating Zone config for $zone");

my $zone_template = `cat /usr/local/admin/.sol11_zone.xml`;

$zone_template =~ s/ZONENAME/$zone/;

my $zone_template_file = '/tmp/zone_template_file.xml';
open ZONE, ">$zone_template_file" or die "ABORT! Cannot write file $zone_template_file: $!";
print ZONE "$zone_template";
close ZONE;

my $zone_config_file = '/tmp/zone_config_file';
system("zonecfg -z $zone create");
system("zonecfg -z $zone remove anet");
system("zonecfg -z $zone set ip-type=shared");

open ZONE, ">$zone_config_file" or die "ABORT! Cannot write file $zone_config_file: $!";
print ZONE "set zonepath=/zones/$zone\n";
print ZONE "set autoboot=false\n";
print ZONE "set pool=$zone\n";
print ZONE "add net\n";
print ZONE "set physical=$setpub\n";
print ZONE "set address=$public_ip".'/24'."\n";
print ZONE "end\n";
print ZONE "add net\n";
print ZONE "set physical=$setstor\n";
print ZONE "set address=$storage_ip".'/24'."\n";
print ZONE "end\n";
close ZONE;

system("zonecfg -z $zone -f /tmp/zone_config_file");

&log ("Creating pool and associating pset");
system("poolcfg -c 'create pool $zone \( string pool.scheduler=\"FSS\" \)' > /dev/null 2>&1");
system("poolcfg -c 'associate pool $zone \( pset $pset \)' > /dev/null 2>&1");
system("pooladm -c > /dev/null 2>&1");
system("pooladm -s > /dev/null 2>&1");

&log ("Cloning zone");
system("zoneadm -z $zone clone -c /tmp/zone_template_file.xml tzmcole");

print "\n";
system("/usr/local/admin/scripts/boot $zone");

&log("\nInitial boot.  Waiting on clean services list.  This can take a few minutes...\n\n");

sleep 15;

system("zlogin $zone svcadm disable svc:/network/login:rlogin > /dev/null 2>&1");
sleep 1;
system("zlogin $zone svcadm disable svc:/application/print/rfc1179:default > /dev/null 2>&1");
sleep 2;

my $counter = 1;

while(1) {
  my $CheckServices = `zlogin $zone svcs -xv 2>&1`;
  if ( $CheckServices eq "" ) {
    sleep 3;
    last;
  }
  &log("Bringing all services online...($counter)\n");
  sleep 10;
  $counter = $counter + 1;
  $CheckServices = `zlogin $zone svcs -xv 2>&1`;
  if ( $CheckServices eq "" ) {
    sleep 3;
    last;
  }
  sleep 10;
  $CheckServices = `zlogin $zone svcs -xv 2>&1`;
  if ( $CheckServices eq "" ) {
    sleep 3;
    last;
  }
  sleep 10;
  $CheckServices = `zlogin $zone svcs -xv 2>&1`;
  if ( $CheckServices eq "" ) {
    sleep 3;
    last;
  }
  sleep 10;
  $CheckServices = `zlogin $zone svcs -xv 2>&1`;
  if ( $CheckServices eq "" ) {
    sleep 3;
    last;
  }
  sleep 10;
  $CheckServices = `zlogin $zone svcs -xv 2>&1`;
  if ( $CheckServices eq "" ) {
    sleep 3;
    last;
  }
  sleep 10;
  $CheckServices = `zlogin $zone svcs -xv 2>&1`;
  if ( $CheckServices eq "" ) {
    sleep 3;
    last;
  }
  if ( $counter > 9 ) {
  &log("Services did not start in alloted time, retrying...\n");
    $counter = 0;
    system("zoneadm -z $zone halt 2>&1");
    sleep 20;
    system("/usr/local/admin/scripts/boot $zone");
  }
}


&log("Setting up etc files in zone $zone...");

system("zlogin $zone /usr/local/admin/scripts/config_zone.pl > /dev/null 2>&1");

open HOSTS, ">>/zones/$zone/root/etc/hosts" or die;
print HOSTS "$public_ip $zone".'.amkor.com'." $zone"."\n";
close HOSTS;

&log("Setting up solaris publisher in zone $zone...");

my $publisher = 'http://augzd10.amkor.com solaris';

if ( $hostname =~ /p0/ ) { $publisher = 'http://augzp10.amkor.com solaris' }

system("zlogin $zone traceroute 10.96.217.92");
system("zlogin $zone traceroute 10.96.217.91");
if ( $uname !~ /i86pc/ ) {
  system("zlogin $zone pkg set-publisher -G '*' -g $publisher");
}
system("zlogin $zone pkg install top pkg://solaris/network/ftp");
sleep 2;
system("zlogin $zone mount /usr/local/admin > /dev/null 2>&1");
sleep 5;
system("zlogin $zone cp /usr/local/admin/authorized_keys2 /root/.ssh");
sleep 2;
system("zlogin $zone cp /usr/local/admin/authorized_keys2 /root/.ssh");
system("zlogin $zone ln -s /usr/bin/mailx /usr/local/bin/mailx");
#system("zlogin $zone cp /usr/local/admin/.ssh_config_centrify2016 /etc/centrifydc/ssh_config");
system("zlogin $zone cp /usr/local/admin/servers/$zone/etc/recent/saptag /");
system("zlogin $zone cp /usr/local/admin/servers/$zone/etc/recent/systag /");
system("zlogin $zone cat /usr/local/admin/servers/$zone/etc/recent/crontabs/root");
system("zlogin $zone /usr/local/admin/hob.ksh");

&log("CHECK /etc/hosts");
&log("Please \"zlogin $zone\" to set new root password and check etc files.");

exit;

sub usage {
  print "Usage:\n";
  print "create_zone.pl <zonename>\n";
  exit 1;
}

sub log {

my ($input) = @_;
my $date = `date +%m-%d-%y_%H:%M:%S`;
chomp($date);

print "$input\n";

open LOG, ">>/usr/local/admin/scripts/create_zone_logs/$zone" or warn "Cannot open log: $!";
print LOG "$date - $input\n";
close LOG;

}# end of log()
