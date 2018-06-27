#!/usr/bin/env bash
# for debug output, uncomment:
#set -x

function help {

	echo "WordPress cleanup -v 0.5 2018-06-26 / peeter@zone.ee

Usage:

safe                sensible cleanup:  backup, rights, reinstall-core, cleanup, reinstall-plugins, init-htaccess,
					harden-uploads, harden-wp-includes, harden-waf, list-oldplugins

forensic            refresh versions:  backup, rights, refresh-core, cleanup-files, refresh-plugins,
                    refresh-themes, init-htaccess, list-oldplugins

tempdb              for old / crashed WPs - create temporary install with new new prefix, update wp and plugins

backup              create full backup
  backup-db         database only
  backup-files      files only

reinstall           reinstall core and plugins (but not themes)
  reinstall-core    forced reinstall of latest WP version (incl cleaning of wp-admin and wp-includes)
  reinstall-plugins reinstall latest versions of plugins
  reinstall-themes  reinstall latest versions of themes
  reinstall-temp    for non-working installs: create temp db

refresh
  refresh-core      forced reinstall of current WP version
  refresh-plugins   reinstall current versions of plugins (for diffing etc)
  refresh-themes    reinstall current versions of inactive themes (for diffing etc)

cleanup             all following cleanups:
  cleanup-plugins   remove unused plugins
  cleanup-themes    remove unused themes
  cleanup-files     clean php files from uploads, empty cache, upgrade folders
  cleanup-misc      transients
  cleanup-git       remove .git and configs
  cleanup-https     search-replace for http > https move (keeping same domain)

harden
  harden-uploads
  harden-wp-content
  harder-wp-includes
  harden-waf

reset-passwords     set all passwords to random
rights              set file & folder rights to 644/755
find-files          look for .php and <?php in uploads
find-files-here     look for .php and <?php in current folder
list-oldplugins     plugins not updted during past 15 minutest
init-git            initialise git, do first commit
init-key            create keypair for ssh
"

}

function init-state {
	if [ ! -f wp-config.php ];
	then
		echo "wp-config.php not found - please run in the root folder of WordPress install!"
		exit 1
	fi

	# make sure we have wp-cli at hand when needed...
	if ! type wp &> /dev/null;
	then
		echo Installing wp-cli...
		curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
		chmod +x wp-cli.phar
		mkdir -p $HOME/bin
		mv wp-cli.phar $HOME/bin/wp
	fi
	# were we successful? the rest of the world depends on it...
	if ! type wp &> /dev/null;
	then
		echo "Apparently installation did not succeed (maybe $HOME/bin is not in PATH?), exiting..."
		exit 1
	fi
}


function init-wpurl {

	if [ "$WPURL" == "" ]; then
		# get site URL for backup names etc
		SITEURL=$(wp option get siteurl | tr -d '[:space:]')

		if [[ $SITEURL != http* ]]; then
			echo "Bad response for wp option get siteurl, possibly unsupported WP or PHP version, quitting ($SITEURL)"
			exit 1
		fi
		WPURL=$(echo "$SITEURL" | sed 's~http[s]*://~~g')
		WPURL_FILESAFE=$(echo "$WPURL" | tr ./ --)
	fi
}

function init-uploads {
	if [ "$UPLOADS" == "" ]; then
		# get site URL for backup names etc
		UPLOADS=$(wp eval "\$d = wp_upload_dir(); echo \$d['basedir'] . PHP_EOL;" | tr -d '[:space:]')
	fi

	if [ "$UPLOADS" == "" ]; then
		echo "Unable to get correct wp_upload_dir, assuming wp-content/uploads"
		UPLOADS="wp-content/uploads"
	fi
}

function init-git {
	if [ ! -d ".git" ]; then
		init-git-settings
		init-git-settings-customuploads
		init-git-create
	else
		echo "Git repo already present, did not initialize or configure."
	fi
}

function init-git-force {
	if [ ! -d ".git" ]; then
		init-git-settings
		init-git-create
	else
		echo "Git repo already present, did not initialize or configure."
	fi
}

function init-git-create {
		git init
		git config user.name "WP clinup"
		git config user.email "clinup@local.dev"
		# ignore chmod differences - usually caused by copying code
		git config core.fileMode false
		git add .
		git commit -q -m "Initial commit"
}

function cleanup-git {
	rm -rf .git
	rm -f .gitignore
	rm -f .gitattributes
}

function init-git-settings {

	echo ".DS_Store
.sass-cache
wp-content/uploads/**
wp-content/upgrade/**
wp-content/backup-db/**
wp-content/cache/**
wp-content/w3tc/**
wp-content/cache/supercache/**
sitemap.xml
sitemap.xml.gz
" > .gitignore
	if [ -f .exclude ]; then
		LINES=$(cat .exclude)
		for LINE in $LINES ; do
			echo "$LINE/**" >> .gitignore
		done
	fi


	# ignore win/*x EOL consipiracy
	
	echo "*.php text eol=lf
*.css text eol=lf
*.scss text eol=lf
*.js text eol=lf
*.md text eol=lf
*.txt text eol=lf
*.svg text eol=lf
*.xml text eol=lf
*.po text eol=lf
" > .gitattributes
}


function init-git-settings-customuploads {
	init-uploads

	UPLOADS_RELATIVE=${UPLOADS#$(pwd)/}

	echo "$UPLOADS_RELATIVE/**
" >> .gitignore
}


function init-key {
	if [ ! -f $HOME/.ssh/id_rsa ]; then
		init-wpurl
		ssh-keygen -t rsa -b 4096 -C "cleanup@$WPURL" -f $HOME/.ssh/id_rsa -q -N ""
		echo "Created new key, public key is:"
		cat $HOME/.ssh/id_rsa.pub
	else
		echo "Found existing key, public key is:"
		cat $HOME/.ssh/id_rsa.pub
	fi
}

function init-harden {

	HARDEN="Options -ExecCGI
RemoveType .php .php3 .phtml .inc
RemoveHandler .php .php3 .phtml .inc

<FilesMatch \"\.(?i:php|php3|phtml|inc)($|\.)\">
    Require all denied
</FilesMatch>

<IfModule mod_php7.c>
  php_flag engine off
</IfModule>
"

	HARDEN_INCLUDES="Options -ExecCGI
RemoveType .php3 .phtml .inc
RemoveHandler .php3 .phtml .inc

<FilesMatch \"\.(?i:php|php3|phtml|inc)($|\.)\">
    Require all denied
</FilesMatch>
<Files wp-tinymce.php>
    Require all granted
</Files>
<Files ms-files.php>
    Require all granted
</Files>
"

	INDEXHTML="<?php
// Silence is golden.

"

}

function init-htaccess {
	echo "# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>

# END WordPress
" > .htaccess

	# just-in-case subfolders have bad htaccess or index.php:

	INDEX="<?php
// Silence is golden.

"
	echo $INDEX > wp-content/index.php
	echo $INDEX > wp-content/plugins/index.php
	echo $INDEX > wp-content/themes/index.php


	rm -f wp-content/.htaccess
	rm -f wp-content/plugins/.htaccess
	rm -f wp-content/themes/.htaccess

}


function commit-if {
	if [ -d ".git" ]; then
		git add .
		git commit -m "$1"
	fi
}

function backup-db {
	init-wpurl

	echo "Creating DB backup..."
	wp db export - | gzip > ../db-backup_${WPURL_FILESAFE}_`date +%d-%m-%Y_%H-%M`.sql.gz
}

function backup-files {
	init-wpurl
	init-uploads

	UPLOADS_RELATIVE=${UPLOADS#$(pwd)/}

	echo "Creating site files backup, EXCLUDING uploads ($UPLOADS_RELATIVE), cache etc..."

	if [ ! -f .exclude ]; then
		tar --exclude="$UPLOADS_RELATIVE" --exclude="wp-content/uploads" --exclude="wp-content/cache" --exclude=".git" -czf ../site-backup_${WPURL_FILESAFE}_`date +%d-%m-%Y_%H-%M`.tar.gz .
	else
		tar --exclude="$UPLOADS_RELATIVE" --exclude="wp-content/uploads" --exclude="wp-content/cache" --exclude=".git" -X .exclude -czf ../site-backup_${WPURL_FILESAFE}_`date +%d-%m-%Y_%H-%M`.tar.gz .
	fi
}

function backup {
	backup-db
	backup-files
}

function rights {
	# set file and folder rights recursively, but not for current script
	echo "Normalizing file and folder rights..."
		find . -type d -print0 | xargs -0 chmod 755
	find . -type f -not -path "$0" -print0 | xargs -0 chmod 644

	commit-if "Normalized rights"
}

function reinstall-core {
	# remove WP admin and includes, re-install core
	echo "Re-installing WP..."
	rm -rf wp-admin/ wp-includes/
	wp core download --version=latest --locale=en_US --force

	# db-update - just in case (add --network for multisite)
	wp core update-db

	# language updates - just in case
	wp core language update

	# good bye, dolly...
	rm -f wp-content/plugins/hello.php
	rm -rf wp-content/plugins/hello-dolly

	commit-if "Re-installed latest version of WordPress"
}

function refresh-core {
	# remove WP admin and includes, re-install core
	echo "Re-installing WP..."
	VERSION=$(wp core version)

	rm -rf wp-admin/ wp-includes/
	wp core download --version=$VERSION --locale=en_US --force

	# good bye, dolly...
	rm -f wp-content/plugins/hello.php
	rm -rf wp-content/plugins/hello-dolly

	commit-if "Re-installed existing version of WordPress"
}


function list-oldplugins {
    # list plugins that have most probably not been reinstalled by this script
	echo "Plugins that were NOT installed during past 15 minutes:"
	find wp-content/plugins -maxdepth 1 -type d -mmin +15 -exec basename {} \;
}

function reinstall-plugins {
	# reinstall all wp plugins that respect standards
	echo "Re-installing plugins (latest version)..."
	plugins=$(wp plugin list --field=name)

	for plugin in $plugins; do
	  wp plugin install $plugin --force
	  commit-if "Re-installed plugin: $plugin"
	done

	# for some reason premium plugins might not update with reinstall
	wp plugin update --all

	wp rewrite flush

	commit-if "Re-installed plugins with latest versions"
}

function refresh-plugins {
	# reinstall all wp plugins that respect standards
	echo "Re-installing plugins (existing version)..."
	plugins=$(wp plugin list --fields=name,version --format=csv | tail -n +2)

	for plugin in $plugins; do
	  wp plugin install $(cut -d, -f1 <<< $plugin) --version=$(cut -d, -f2 <<< $plugin) --force
	  commit-if "Refreshed plugin: $plugin"
	done

	wp rewrite flush
}

function reinstall-themes {
	# reinstall all wp plugins that respect standards
	echo "Re-installing themes (latest version)..."

	themes=$(wp theme list --field=name)

	for theme in $themes; do
	  wp theme install $theme --force
	  commit-if "Re-installed theme: $theme"
	done
}

function refresh-themes {
	# reinstall inactive themes
	echo "Re-installing themes (existing version)..."
	themes=$(wp theme list --status=inactive --fields=name,version --format=csv | tail -n +2)

	for theme in $themes; do
	  wp theme install $(cut -d, -f1 <<< $theme) --version=$(cut -d, -f2 <<< $theme) --force
	  commit-if "Refreshed theme: $theme"
	done
}

function cleanup-plugins {
	# remove unused themes
	echo "Removing unused plugins..."
	wp plugin delete $(wp plugin list --field=name --status=inactive)

	commit-if "Removed unused plugins"
}

function cleanup-themes {
	# remove unused themes
	echo "Removing unused themes..."
	wp theme delete $(wp theme list --field=name --status=inactive)

	commit-if "Removed unused themes"
}

function cleanup-files {
	init-uploads

	# clean upgrade & cache folder
	echo "Cleaning caches..."
	rm -rf wp-content/upgrade/*
	rm -rf wp-content/cache/*
	rm -rf wp-content/w3tc/*

	# clean possible php-executabe files from uploads
	echo "Cleaning uploads..."

	find $UPLOADS \( -name '*.php' -o -name '*.phtlm' -o -name '*.inc' -o -name '*.php3' \) -type f -delete
	find $UPLOADS -type d -empty -delete

	commit-if "Cleaned wp-content"
}

function find-files {
	init-uploads

	echo "Searching by extensions in uploads..."
	find $UPLOADS \( -name '*.php' -o -name '*.phtlm' -o -name '*.inc' -o -name '*.php3' \) -type f

	echo "Grepping by <?php in uploads..."
	grep -rnw $UPLOADS -e "<?php"

}

function find-files-here {

	echo "Searching by extensions in current folder..."
	find . \( -name '*.php' -o -name '*.phtlm' -o -name '*.inc' -o -name '*.php3' \) -type f

	echo "Grepping by <?php in in current folder..."
	grep -rnw . -e "<?php"

}


function cleanup-misc {
	wp transient delete-all
}

function reset-passwords {
	NEW_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
	wp user update $(wp user list --field=id) --user_pass=$NEW_PASSWORD
	echo "All passwords set to $NEW_PASSWORD"
}

function harden-uploads {
	init-harden
	init-uploads

	echo "Adding .htaccess to uploads..."
	echo "$HARDEN" > $UPLOADS/.htaccess

	commit-if "Added .htaccess to uploads"
}

function unharden-uploads {
	init-uploads

	echo "Removing.htaccess from uploads..."
	rm -f $UPLOADS/.htaccess

	commit-if "Removed .htaccess from uploads"
}

function harden-wp-content {
	init-harden

	echo "Adding .htaccess to wp-content..."
	echo "$HARDEN" > wp-content/.htaccess

	commit-if "Added .htaccess to wp-content"
}

function unharden-wp-content {
	echo "Removing.htaccess from wp-content..."
	rm -f wp-content/.htaccess

	commit-if "Removed .htaccess from wp-content"
}

function harden-wp-includes {
	init-harden

	echo "Adding .htaccess to wp-includes..."
	echo "$HARDEN_INCLUDES" > wp-includes/.htaccess

	commit-if "Added .htaccess to wp-includes"
}

function unharden-wp-includes {
	echo "Removing.htaccess from wp-includes..."
	rm -f wp-includes/.htaccess

	commit-if "Removed .htaccess from wp-content"
}

function unharden-waf {
	if grep -q "# 6G FIREWALL/BLACKLIST" .htaccess; then
		sed -i.bak '/# 6G FIREWALL/,/# 6G END/d' .htaccess
		rm -f .htaccess.bak
	fi
}

function harden-waf {
	# so it can be used to refresh rules
	unharden-waf
	init-harden

	HARDEN_WAF=$(curl https://gist.githubusercontent.com/petskratt/17fdb56c75800fc38797a7c5bd1d1127/raw/.htaccess)
	HTACCESS=$(cat .htaccess)
	echo "$HARDEN_WAF
$HTACCESS" > .htaccess

	commit-if "Added 6G blacklist to .htaccess"
}

function cleanup {
	cleanup-files
	if ! $(wp core is-installed --network); then
		# network install needs more complex approach...
		cleanup-plugins
		cleanup-themes
	fi
	cleanup-misc
}

function cleanup-https {
	init-wpurl

	wp search-replace http://$WPURL https://$WPURL --skip-columns=guid

	wp rewrite flush
}

function tempdb {

	# todo - find prefix from conf, ensure it is safe to use without user intervention

	if [ -z "$1" ]
	  then
		echo "Please supply current prefix as argument, perhaps:"
		grep '$table_prefix' wp-config.php
		exit 1
	fi


	cp wp-config.php wp-config_clinup_temp.php

	echo "Original prefix:"
	grep '$table_prefix' wp-config.php

	sed -i.bak s/$1/clinup_temp_/g wp-config.php
	rm -f wp-config.php.bak

	echo "Temporary prefix:"
	grep '$table_prefix' wp-config.php

	read -n1 -r -p 'Does that seem OK as temp prefix? Press Y to continue:' key

	if [ "$key" == "Y" ]; then
		echo 'OK, trying to reinstall...'
	else
		echo 'Cancelling & restoring wp-config.php...'
		rm -f wp-config.php
		mv wp-config_clinup_temp.php wp-config.php
		exit 1
	fi

	rights

	# prefix uueks

	rm -rf wp-admin/ wp-includes/
	wp core download --version=latest --locale=en_US --force

	wp core install --url=clinup.local --title=Temporary --admin_user=clinup --admin_email=clinup@clinup.local --skip-email

	# language updates - just in case
	wp core language update

	# good bye, dolly...
	rm -f wp-content/plugins/hello.php
	rm -rf wp-content/plugins/hello-dolly

	reinstall-plugins
	init-htaccess

	~/bin/wp db query "SET GROUP_CONCAT_MAX_LEN=10000; SET @tbls = (SELECT GROUP_CONCAT(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_NAME LIKE 'clinup_temp_%'); SET @delStmt = CONCAT('DROP TABLE ', @tbls); SELECT @delStmt; PREPARE stmt FROM @delStmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;"

	# restore wp-config
	rm -f wp-config.php
	mv wp-config_clinup_temp.php wp-config.php

	list-oldplugins

}


function safe {
	backup
	rights
	reinstall-core
	cleanup
	reinstall-plugins
	init-htaccess
	harden-uploads
	harden-wp-includes
	harden-waf
	list-oldplugins
}

function forensic {
	backup
	rights
	refresh-core
	cleanup-files
	refresh-plugins
	refresh-themes
	init-htaccess
	list-oldplugins
}

if [ "$1" != "help" ] && [ "$1" != "find-files-here" ]; then
	init-state
fi

$1 $2