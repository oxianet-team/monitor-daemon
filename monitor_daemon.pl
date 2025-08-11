#!/usr/bin/perl
use strict;
use warnings;

# Configuration
my $api_url = '';  # URL du point de terminaison API
my $uuid = '';     # UUID de la machine
my $token = '';    # Jeton API
my $debug = 0;     # Mode débogage
my $rawOutput = 0;  # Mode sortie brute
my $jsonOnly = 0;  # Mode affichage JSON uniquement

# Fonction pour convertir les unités en MB
sub convert_to_mb {
    my ($value) = @_;
    if ($value =~ /(\d+(\.\d+)?)([KMGTP])/i) {
        my $number = $1;
        my $unit = uc($3);
        my %unit_multiplier = (
          'K' => 1 / 1024,
          'M' => 1,
          'G' => 1024,
          'T' => 1024 * 1024,
          'P' => 1024 * 1024 * 1024,
        );
        return sprintf("%.2f", $number * $unit_multiplier{$unit});
    }
    return $value;
}

# Analyse simple des arguments
foreach my $arg (@ARGV) {
    if ($arg =~ /^--api=(.+)$/) {
        $api_url = $1;
    } elsif ($arg =~ /^--uuid=(.+)$/) {
        $uuid = $1;
    } elsif ($arg =~ /^--token=(.+)$/) {
        $token = $1;
    } elsif ($arg eq '--debug') {
        $debug = 1;
    } elsif ($arg eq '--raw-output') {
        $rawOutput = 1;
    } elsif ($arg eq '--json-only') {
        $jsonOnly = 1;
    } elsif ($arg eq '--help') {
        print "Usage: $0 --api=URL --uuid=UUID --token=token [--debug] [--raw] [--json-only]\n";
        print "  --api=URL   : URL du point de terminaison API\n";
        print "  --uuid=UUID : UUID de la machine\n";
        print "  --token=token : Jeton API\n";
        print "  --debug     : Activer le mode débogage\n";
        print "  --raw       : Mode sortie brute\n";
        print "  --json-only : Afficher uniquement le JSON généré sans l'envoyer\n";
        exit;
    } else {
        die "Argument inconnu: $arg\n";
    }
}

# Vérification des paramètres requis
if ($jsonOnly) {
    # En mode JSON uniquement, seul l'UUID est requis
    die "Usage minimal en mode JSON uniquement: $0 --uuid=UUID --json-only\n" unless $uuid;
} else {
    # En mode normal, tous les paramètres sont requis
    die "Usage minimal: $0 --api=URL --uuid=UUID --token=token\n" unless $api_url && $uuid && $token;
}

# Fonction de journalisation
sub console_log {
    my ($message) = @_;
    print "[" . localtime() . "] $message\n" if $debug;
}

console_log("Démarrage du démon de surveillance...");
console_log("URL API: $api_url");
console_log("UUID: $uuid");
console_log("TOKEN $token");

# Vérification de la connectivité API seulement si on n'est pas en mode JSON uniquement
unless ($jsonOnly) {
    console_log("Ping de l'URL API pour vérifier la connectivité...");
    my $ping_cmd = "curl -s -o /dev/null -w \"%{http_code}\" $api_url";
    my $ping_status = `$ping_cmd`;
    chomp($ping_status);

    if ($ping_status =~ /^0\d\d$/) {
        die "FATAL: L'URL API a retourné le statut $ping_status. Impossible de continuer.";
    }

    if ($api_url !~ /\/$/) {
        $api_url .= '/';
    }

    $api_url .= "api/distant/data/$uuid";
}

eval {
    # Récupération du nom d'hôte
    my $hostname = `hostname`;
    chomp($hostname);

    # Récupération des informations d'utilisation du disque (en excluant les systèmes de fichiers temporaires)
    my $disk_usage = '';
    my @df_output = `df -h | grep -v "tmpfs\\|devtmpfs\\|udev"`;
    my $header_included = 0;
    foreach my $line (@df_output) {
        chomp($line);
        if ($line =~ /sys/i && !$header_included) {
            $disk_usage .= "$line;";
            $header_included = 1;
        } elsif ($line =~ /^\//) {
            $disk_usage .= "$line;";
        }
    }

    # Récupération de la charge CPU (moyenne sur 1 minute)
    my $loadavg = `cat /proc/loadavg`;
    chomp($loadavg);
    my ($cpu_load) = split(/\s+/, $loadavg);

    # Récupération du pourcentage d'utilisation CPU
    my $cpu_percent = '';
    my $top_output = `top -bn1 | grep "Cpu(s)"`;
    if ($top_output =~ /(\d+\.\d+)\s*id/) {
        my $idle = $1;
        $cpu_percent = 100 - $idle;
    }

    # Récupération de l'utilisation de la mémoire
    my $mem_info = `free -m | grep Mem`;
    chomp($mem_info);
    my @mem_parts = split(/\s+/, $mem_info);
    my $mem_total = $mem_parts[1] || 0;
    my $mem_used = $mem_parts[2] || 0;
    my $mem_percent = 0;
    if ($mem_total > 0) {
        $mem_percent = sprintf("%.2f", ($mem_used / $mem_total) * 100);
    }

    # Récupération des informations de temps de fonctionnement
    my $uptime_output = `uptime -p`;
    chomp($uptime_output);
    $uptime_output =~ s/^up\s+//;

    # Récupération de la version du noyau
    my $kernel_version = `uname -r`;
    chomp($kernel_version);

    # Récupération des informations sur le système d'exploitation
    my $os_info = "";
    if (-e "/etc/os-release") {
        $os_info = `cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2`;
        chomp($os_info);
        $os_info =~ s/^"//;
        $os_info =~ s/"$//;
    }

    # Analyse de l'utilisation du disque en données structurées
    my @disks = ();
    shift @df_output if $header_included;
    foreach my $line (@df_output) {
        chomp($line);
        if ($line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.+)$/) {
            my $filesystem = $1;
            my $size = convert_to_mb($2);
            my $used = convert_to_mb($3);
            my $mounted_on = $6;

            $filesystem =~ s/\\/\\\\/g;
            $filesystem =~ s/"/\\"/g;
            $mounted_on =~ s/\\/\\\\/g;
            $mounted_on =~ s/"/\\"/g;

            my $disk_data = "{";
            $disk_data .= "\\\"filesystem\\\":\\\"$filesystem\\\",";
            $disk_data .= "\\\"size\\\":\\\"$size\\\",";
            $disk_data .= "\\\"used\\\":\\\"$used\\\",";
            $disk_data .= "\\\"mounted_on\\\":\\\"$mounted_on\\\"";
            $disk_data .= "}";
            push @disks, $disk_data;
        }
    }
    my $disks_json = join(",", @disks);

    # Collecte de l'utilisation des ressources des conteneurs Docker (cgroup v2)
    my @docker_containers = ();

    # Vérification des cgroups Docker dans /sys/fs/cgroup/system.slice
    if (-d "/sys/fs/cgroup/system.slice") {
        opendir(my $dh, "/sys/fs/cgroup/system.slice") or console_log("Cannot open /sys/fs/cgroup/system.slice: $!");
        my %first_cpu_usage;
        my %container_paths;

        # Détermination du nombre de cœurs CPU pour le calcul du pourcentage
        my $cpu_cores = 1; # Valeur par défaut
        if (-r "/proc/cpuinfo") {
            my $cpu_info = `grep -c processor /proc/cpuinfo`;
            chomp($cpu_info);
            $cpu_cores = $cpu_info if $cpu_info =~ /^\d+$/ && $cpu_info > 0;
        }

        # Premier passage : collecte de l'utilisation CPU initiale
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./; # Skip . and ..
            next unless $entry =~ /^docker-([0-9a-f]{12,})\.scope$/; # Match Docker container scopes

            my $container_hash = $1;
            my $cgroup_path = "/sys/fs/cgroup/system.slice/$entry";

            if (-r "$cgroup_path/cpu.stat") {
                my $cpu_stat = `cat $cgroup_path/cpu.stat`;
                if ($cpu_stat =~ /^usage_usec\s+(\d+)/m) {
                    $first_cpu_usage{$container_hash} = $1; # Stockage de l'utilisation initiale en microsecondes
                    $container_paths{$container_hash} = $cgroup_path;
                }
            }
        }
        closedir($dh);

        # Attente d'une seconde pour mesurer le delta d'utilisation CPU
        sleep(1);

        # Second passage : collecte de l'utilisation CPU finale et autres métriques
        opendir($dh, "/sys/fs/cgroup/system.slice") or console_log("Cannot open /sys/fs/cgroup/system.slice: $!");
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;
            next unless $entry =~ /^docker-([0-9a-f]{12,})\.scope$/;

            my $container_hash = $1;
            my $cgroup_path = $container_paths{$container_hash};

            next unless defined $cgroup_path; # Ignorer si nous n'avons pas obtenu l'utilisation CPU initiale

            # Obtention du pourcentage d'utilisation CPU
            my $cpu_usage_percent = 0;
            if (-r "$cgroup_path/cpu.stat") {
                my $cpu_stat = `cat $cgroup_path/cpu.stat`;
                if ($cpu_stat =~ /^usage_usec\s+(\d+)/m) {
                    my $final_cpu_usage = $1;
                    my $cpu_usage_delta = $final_cpu_usage - ($first_cpu_usage{$container_hash} || 0);
                    # Calcul du pourcentage : (delta en usec / intervalle en usec) * 100 / nombre de cœurs
                    $cpu_usage_percent = sprintf("%.2f", ($cpu_usage_delta / 1_000_000) * 100 / $cpu_cores);
                }
            }

            # Récupération de l'utilisation mémoire (depuis memory.current)
            my $memory_usage_mb = 0;
            if (-r "$cgroup_path/memory.current") {
                my $memory_bytes = `cat $cgroup_path/memory.current`;
                chomp($memory_bytes);
                $memory_usage_mb = sprintf("%.2f", $memory_bytes / (1024 * 1024)) if $memory_bytes =~ /^\d+$/;
            }

            # Récupération du nom du conteneur
            my $container_name = '';
            if ($container_hash) {
              my $container_id = substr($container_hash, 0, 12);
              # Test si la commande docker est disponible et accessible avec les permissions actuelles
              my $docker_cmd = `which docker`;
              chomp($docker_cmd);
              if ($docker_cmd) {
                  # Récupération du nom du conteneur à partir de l'ID
                  my $container_info = `docker ps --filter "id=$container_id" --format "{{.Names}}" 2>/dev/null`;
                  chomp($container_info);
                  if ($container_info) {
                      $container_name = $container_info;
                  }
              }
            }

            if ($container_name eq '') {
                $container_name = "inconnu";
            }

            # Stockage des métriques
            my $container_data = "{";
            $container_data .= "\\\"container_hash\\\":\\\"$container_hash\\\",";
            $container_data .= "\\\"container_name\\\":\\\"$container_name\\\",";
            $container_data .= "\\\"cpu_usage_percent\\\":\\\"$cpu_usage_percent\\\",";
            $container_data .= "\\\"memory_usage_mb\\\":\\\"$memory_usage_mb\\\"";
            $container_data .= "}";
            push @docker_containers, $container_data;
        }
        closedir($dh);
    } else {
        console_log("Aucun system.slice trouvé ou cgroups non accessibles.");
    }

    my $docker_json = join(",", @docker_containers);

    # Préparation des données JSON structurées
    my $json_data = "{";
    $json_data .= "\\\"timestamp\\\":\\\"" . time() . "\\\",";
    $json_data .= "\\\"system\\\": {";
    $json_data .= "\\\"hostname\\\":\\\"$hostname\\\",";
    $json_data .= "\\\"kernel\\\":\\\"$kernel_version\\\",";
    $json_data .= "\\\"os\\\":\\\"$os_info\\\",";
    $json_data .= "\\\"uptime\\\":\\\"$uptime_output\\\"";
    $json_data .= "},";

    $json_data .= "\\\"cpu\\\": {";
    $json_data .= "\\\"load\\\":\\\"$cpu_load\\\",";
    $json_data .= "\\\"usage_percent\\\":\\\"$cpu_percent\\\"";
    $json_data .= "},";

    $json_data .= "\\\"memory\\\": {";
    $json_data .= "\\\"total_mb\\\":\\\"$mem_total\\\",";
    $json_data .= "\\\"used_mb\\\":\\\"$mem_used\\\",";
    $json_data .= "\\\"usage_percent\\\":\\\"$mem_percent\\\"";
    $json_data .= "},";

    $json_data .= "\\\"disks\\\": [" . $disks_json . "],";
    $json_data .= "\\\"docker\\\": [" . $docker_json . "]";

    $json_data .= "}";

    console_log("Données JSON: $json_data");

    # Si mode JSON uniquement, afficher le JSON et terminer
    if ($jsonOnly) {
        # Déséchapper les caractères pour l'affichage
        my $display_json = $json_data;
        $display_json =~ s/\\"/"/g;  # Remplacer \" par "
        $display_json =~ s/\\\\/\\/g; # Remplacer \\ par \
        print $display_json . "\n";
    } else {
        # Envoi des données à l'API en utilisant curl
        console_log("Envoi des données système à $api_url");

        my $curl_cmd = "curl -s -X POST \"$api_url\" -H \"Content-Type: application/json\" -H \"Authorization: Bearer $token\" -d \"$json_data\"";
        my $response = `$curl_cmd`;

        if ($rawOutput) {
            print $response;
        } else {
            console_log("Réponse API: $response");
        }
    }
};

if ($@) {
    console_log("Erreur: $@");
}
