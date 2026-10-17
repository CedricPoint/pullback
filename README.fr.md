# pullback

[English](README.md) · **Français**

**Sauvegarder des serveurs entiers sur une machine chez vous, en tirant.** Un
fichier de configuration, trois commandes, et un serveur qui se fait pirater
ne peut rien faire aux copies de lui-même : il n'en a ni les identifiants, ni
le chemin.

[![CI](https://github.com/CedricPoint/pullback/actions/workflows/ci.yml/badge.svg)](https://github.com/CedricPoint/pullback/actions/workflows/ci.yml)
[![bash](https://img.shields.io/badge/bash-4%2B-brightgreen.svg)](bin/pullback)
[![dépendances](https://img.shields.io/badge/d%C3%A9pendances-ssh%20%2B%20rsync-brightgreen.svg)](#ce-quil-lui-faut)
[![licence](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

```console
$ pullback run

2026-10-17 03:30:02  pullback → /srv/backups
2026-10-17 03:30:02  web  →  2026-10-17T033002Z
2026-10-17 03:30:02      /var/www
2026-10-17 03:30:04      /etc/nginx
2026-10-17 03:30:11  ✓ web  2 GB in 0m
2026-10-17 03:30:11  app  →  2026-10-17T033011Z
2026-10-17 03:30:14      postgres: appdb
2026-10-17 03:30:26        412 MB
2026-10-17 03:30:26  ✓ app  1 GB in 0m
2026-10-17 03:30:26  ✓ 2 server(s) in 15m

$ pullback status

SERVER               LAST         SNAPSHOTS  SIZE      STATE
web                  7h 20m       28         94 GB     ok
app                  7h 20m       28         31 GB     ok
```

*(L'outil s'exprime en anglais : sa sortie finit dans un journal, un courriel
de cron ou une alerte, où le reste l'est déjà.)*

## Trois commandes et c'est en route

```bash
git clone https://github.com/CedricPoint/pullback.git
cd pullback && sudo ./install.sh

sudo nano /etc/pullback/pullback.conf    # une ligne `server` par machine
pullback doctor                          # ssh, outils, chemins — avant d'y croire
pullback run                             # la première sauvegarde
```

Puis choisissez l'horaire — l'installateur affiche les deux lignes :

```bash
cp /usr/local/lib/pullback/share/pullback.{service,timer} /etc/systemd/system/
systemctl enable --now pullback.timer
```

Il n'y a volontairement pas de `curl … | sh` ici. Donner un script non lu à un
shell root est une habitude qu'il vaut mieux ne pas répandre.

## La configuration, en entier

```sh
DEST=/srv/backups

KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12

NOTIFY_COMMAND=/usr/local/bin/pullback-notify   # appelé : <niveau> <message>

server web \
  --host root@198.51.100.10 \
  --path /var/www \
  --path /etc/nginx \
  --exclude '*.log' \
  --exclude 'node_modules'

server app \
  --host deploy@198.51.100.11 \
  --path /srv/app \
  --postgres appdb \
  --mysql legacy
```

C'est tout. Une machine joignable uniquement via une autre prend
`--ssh '-J rebond@passerelle'` ; un dump qui demande un autre utilisateur prend
une ligne `PG_DUMP_COMMAND="sudo -n -u postgres pg_dump …"`.

## Pourquoi tirer plutôt que pousser

Si c'est le serveur qui pousse, il détient une clé vers le dépôt de
sauvegardes. Le jour où quelqu'un entre, la première chose utile à faire est
d'effacer les sauvegardes — et cette clé le permet. Tirer inverse le sens : la
clé est sur la machine de sauvegarde, c'est elle qui va chercher, et rien sur
le serveur ne sait où vivent les copies.

Le durcissement va un cran plus loin, et `pullback doctor` affiche la ligne :

```
command="rrsync -ro /",restrict ssh-ed25519 AAAA… pullback
```

Avec ça dans le `authorized_keys` du serveur, la clé de sauvegarde peut lire,
et seulement lire — même depuis la machine de sauvegarde.

## Ce que ça coûte en disque

Chaque exécution crée un nouveau dossier de sauvegarde, et chaque fichier
inchangé est un **lien dur** vers celui de la sauvegarde précédente. Trente
jours d'historique coûtent trente jours de *modifications*, pas trente copies.
Supprimer une vieille sauvegarde ne libère que ce que rien de plus récent ne
désigne — c'est pourquoi les réglages par défaut gardent un an de mensuelles
sans que personne ne s'en aperçoive.

```
/srv/backups/web/
    2026-10-17T033002Z/
        files/var/www/…
        files/etc/nginx/…
        databases/postgres-appdb.dump.gz
        manifest.txt
        MANIFEST.sha256
    latest -> 2026-10-17T033002Z
    last-success
```

Les bases sont dumpées à l'autre bout et **transmises directement ici** : la
machine sauvegardée n'a jamais à trouver la place d'une copie d'elle-même.

## Échouer bruyamment

C'est la partie que les scripts maison ratent le plus souvent, et c'est celle
qui compte : une sauvegarde à laquelle on ne pense plus est celle qui ne tourne
plus.

- **Une sauvegarde devient réelle en un seul `mv`.** Elle est construite dans
  `.incomplete-…` et renommée seulement quand chaque fichier et chaque dump ont
  réussi. Une exécution qui meurt en route laisse la dernière bonne sauvegarde
  exactement où elle était, et laisse ses propres débris à examiner.
- **Rien n'est supprimé avant ça.** L'élagage se fait après une réussite,
  jamais avant, et uniquement pour des noms de dossier qui correspondent
  exactement à un horodatage de sauvegarde.
- **Un dump vide n'est pas une sauvegarde.** En dessous de `MIN_DUMP_BYTES`,
  l'exécution échoue au lieu d'écraser la bonne.
- **`pipefail` à l'autre bout aussi.** `pg_dump | gzip` via ssh renvoie le code
  de gzip : le dump peut mourir en route, gzip compresse joyeusement la sortie
  tronquée, et ssh annonce une réussite. La commande est encapsulée pour que
  l'échec revienne. C'est le bug qui produit une sauvegarde parfaite en
  apparence jusqu'au jour où on en a besoin.
- **rsync 24 est un avertissement, pas un échec.** Des fichiers qui
  disparaissent pendant la copie, c'est la vie d'un serveur en production. Tout
  autre code d'erreur arrête l'exécution de ce serveur.
- **`pullback status` sort en non-zéro** dès qu'un serveur dépasse
  `MAX_AGE_HOURS`. Branchez votre supervision sur cette ligne et un cron qui a
  cessé de se déclencher devient une alerte au lieu d'une surprise.
- **On vous prévient aussi quand ça remarche**, pas seulement quand ça casse.

## Et pour récupérer

La partie que la plupart des scripts de sauvegarde n'ont jamais.

```bash
pullback list web --contents                     # ce qu'il y a dedans
pullback restore web --into /tmp/recup           # tout
pullback restore web --into /tmp/recup --path /etc/nginx
pullback restore app --into /tmp/recup --database postgres-appdb
pullback verify --all                            # revérifier toutes les empreintes
```

Il ne restaure jamais en place : `--into` est obligatoire, et il refuse un
dossier non vide sauf si vous dites `--force`. Pour une base, il sort le dump
et **affiche** la commande pour le charger :

```
  to load it back, when you have decided to:
  gunzip -c /tmp/recup/databases/postgres-appdb.dump.gz | pg_restore --clean --if-exists -d appdb
```

Affichée, pas exécutée. Charger un dump est la seule étape qui détruit quelque
chose qui fonctionne actuellement.

## Ce qu'il lui faut

Sur la machine de sauvegarde : `bash` 4+, `rsync`, `ssh`, `sha256sum`, et
`flock` si vous ne voulez pas que deux crons se chevauchent. Sur les serveurs :
`bash`, `rsync`, et `pg_dump` ou `mysqldump` si vous demandez des bases.
`pullback doctor` vérifie tout ça, des deux côtés, et vous dit ce qui manque
avant que quatre heures du matin ne le fasse.

Rien d'autre. Pas d'agent, pas de démon, pas de base de données, aucun
environnement d'exécution.

## Tests

85 vérifications, contre un serveur factice qui ne l'est que par le réseau :
vrai rsync, vrais liens durs, vrai gzip, vraies empreintes, vraies permissions
— la commande ssh est simplement pointée vers un script qui exécute l'autre
bout localement.

```bash
./test/run.sh
```

Ils couvrent ce qui est difficile à faire correctement et facile à croire
réussi : qu'une deuxième exécution lie bien en dur les fichiers inchangés et ne
lie surtout pas un fichier modifié, qu'un dump qui meurt en route fait échouer
l'exécution, qu'une exécution ratée laisse la sauvegarde précédente comme
`latest`, que l'élagage garde exactement ce que dit le plan de rétention et que
`--dry-run` ne supprime rien, que la suppression refuse tout ce qui n'est pas
un dossier de sauvegarde, et qu'un nom de serveur mal tapé est une erreur et
non une exécution satisfaite qui n'a rien sauvegardé.

## Licence

MIT
