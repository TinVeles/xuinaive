#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
	echo "Please run this script as root."
	exit 1
fi

# Function to get web roots from Nginx configuration
get_web_roots() {
	nginx -T 2>/dev/null | grep "root " | awk '{print $2}' | sed 's/;//g' | sort -u
}

# Logging function
log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/backup_script.log
}

# Function to perform backup
backup() {
	# Ask for backup directory with default
	while true; do
		read -p "Enter the backup directory path (default /backup): " BACKUP_DIR
		BACKUP_DIR="${BACKUP_DIR:-/backup}"
		if mkdir -p "$BACKUP_DIR" 2>/dev/null; then
			break
		else
			echo "Failed to create backup directory. Please enter a valid path."
		fi
	done
	
	# Get current date and timestamp
	BACKUP_DATE=$(date +%F)
	BACKUP_TIMESTAMP=$(date +%H-%M-%S)
	BACKUP_DIR_DATE="$BACKUP_DIR/$BACKUP_DATE"
	BACKUP_DIR_TIMESTAMP="$BACKUP_DIR_DATE/$BACKUP_TIMESTAMP"
	mkdir -p "$BACKUP_DIR_TIMESTAMP"
	
	# Present menu for backup selection with exit option
	while true; do
		echo "Select components to backup:"
		echo "1. Nginx configuration"
		echo "2. 3x-ui database"
		echo "3. 3x-ui config.json"
		echo "4. Website files"
		echo "5. All of the above"
		echo "0. Exit"
		read -p "Enter your choice (0-5): " OPTION
		
		case $OPTION in
			1)
				# Backup Nginx configuration
				echo "Creating backup of Nginx configuration..."
				tar -czf "$BACKUP_DIR_TIMESTAMP/nginx-$BACKUP_TIMESTAMP.tar.gz" /etc/nginx
				echo "Backup completed."
				log "Nginx configuration backed up to $BACKUP_DIR_TIMESTAMP/nginx-$BACKUP_TIMESTAMP.tar.gz"
				;;
			2)
				# Backup 3x-ui database
				echo "Creating backup of 3x-ui database..."
				tar -czf "$BACKUP_DIR_TIMESTAMP/x-ui-sql-$BACKUP_TIMESTAMP.tar.gz" /etc/x-ui
				echo "Backup completed."
				log "3x-ui database backed up to $BACKUP_DIR_TIMESTAMP/x-ui-sql-$BACKUP_TIMESTAMP.tar.gz"
				;;
			3)
				# Backup 3x-ui config.json
				echo "Creating backup of 3x-ui config.json..."
				tar -czf "$BACKUP_DIR_TIMESTAMP/config-$BACKUP_TIMESTAMP.tar.gz" /usr/local/x-ui/bin/config.json
				echo "Backup completed."
				log "3x-ui config.json backed up to $BACKUP_DIR_TIMESTAMP/config-$BACKUP_TIMESTAMP.tar.gz"
				;;
			4)
				# Backup website files
				echo "Creating backup of website files..."
				WEB_ROOTS=$(get_web_roots)
				echo "Web roots: $WEB_ROOTS"
				for WEB_ROOT in $WEB_ROOTS; do
					if [ -d "$WEB_ROOT" ]; then
						tar -czf "$BACKUP_DIR_TIMESTAMP/website-${WEB_ROOT//\//_}-$BACKUP_TIMESTAMP.tar.gz" -P "$WEB_ROOT"
						echo "Backed up $WEB_ROOT"
						log "Website files for $WEB_ROOT backed up to $BACKUP_DIR_TIMESTAMP/website-${WEB_ROOT//\//_}-$BACKUP_TIMESTAMP.tar.gz"
					else
						echo "Web root $WEB_ROOT does not exist. Skipping backup."
					fi
				done
				echo "Backup completed."
				;;
			5)
				# Backup all components
				echo "Creating backup of all components..."
				tar -czf "$BACKUP_DIR_TIMESTAMP/nginx-$BACKUP_TIMESTAMP.tar.gz" /etc/nginx
				tar -czf "$BACKUP_DIR_TIMESTAMP/x-ui-sql-$BACKUP_TIMESTAMP.tar.gz" /etc/x-ui
				tar -czf "$BACKUP_DIR_TIMESTAMP/config-$BACKUP_TIMESTAMP.tar.gz" /usr/local/x-ui/bin/config.json
				WEB_ROOTS=$(get_web_roots)
				for WEB_ROOT in $WEB_ROOTS; do
					if [ -d "$WEB_ROOT" ]; then
						tar -czf "$BACKUP_DIR_TIMESTAMP/website-${WEB_ROOT//\//_}-$BACKUP_TIMESTAMP.tar.gz" -P "$WEB_ROOT"
						log "Website files for $WEB_ROOT backed up to $BACKUP_DIR_TIMESTAMP/website-${WEB_ROOT//\//_}-$BACKUP_TIMESTAMP.tar.gz"
					else
						echo "Web root $WEB_ROOT does not exist. Skipping backup."
					fi
				done
				echo "Backup completed."
				;;
			0)
				echo "Exiting backup selection."
				break
				;;
			*)
				echo "Invalid choice. Please select a valid option."
				;;
		esac
		read -p "Press Enter to continue..."
	done
}

# Function to perform restore
restore() {
	# Ask for backup directory with default
	while true; do
		read -p "Enter the backup directory path (default /backup): " BACKUP_DIR
		BACKUP_DIR="${BACKUP_DIR:-/backup}"
		if [ -d "$BACKUP_DIR" ]; then
			break
		else
			echo "Backup directory does not exist. Please enter a valid path."
		fi
	done
	
	# List available backup dates with exit option
	BACKUP_DATES=($(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;))
	if [ ${#BACKUP_DATES[@]} -eq 0 ]; then
		echo "No backup dates found."
		return
	fi
	
	echo "Available backup dates:"
	select BACKUP_DATE in "${BACKUP_DATES[@]}" "Exit"; do
		if [ "$BACKUP_DATE" == "Exit" ]; then
			echo "Exiting restore selection."
			return
		elif [ -n "$BACKUP_DATE" ]; then
			BACKUP_DIR_DATE="$BACKUP_DIR/$BACKUP_DATE"
			break
		else
			echo "Please select a valid option."
		fi
	done
	
	# List all backup timestamps in the selected date directory
	BACKUP_TIMESTAMPS=($(find "$BACKUP_DIR_DATE" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;))
	if [ ${#BACKUP_TIMESTAMPS[@]} -eq 0 ]; then
		echo "No backup timestamps found in $BACKUP_DIR_DATE."
		return
	fi
	
	echo "Available backup timestamps in $BACKUP_DIR_DATE:"
	select BACKUP_TIMESTAMP in "${BACKUP_TIMESTAMPS[@]}" "Exit"; do
		if [ "$BACKUP_TIMESTAMP" == "Exit" ]; then
			echo "Exiting restore selection."
			return
		elif [ -n "$BACKUP_TIMESTAMP" ]; then
			BACKUP_DIR_TIMESTAMP="$BACKUP_DIR_DATE/$BACKUP_TIMESTAMP"
			echo "Restoring from $BACKUP_DIR_TIMESTAMP..."
			for FILE in "$BACKUP_DIR_TIMESTAMP"/*.tar.gz; do
				echo "Restoring $FILE..."
				tar -xzf "$FILE" -C /
				log "Restored $FILE from $BACKUP_DIR_TIMESTAMP"
			done
			echo "Restore completed."
			read -p "Press Enter to continue..."
		else
			echo "Please select a valid option."
		fi
	done
	
	# Start services after restore
	echo "Starting nginx and x-ui services..."
	systemctl start nginx
	systemctl start x-ui
	log "Services restarted after restore operation."
}

# Main menu with exit option
while true; do
	echo "------------------------"
	echo "  Backup/Restore Menu  "
	echo "------------------------"
	echo "1. Perform Backup"
	echo "2. Perform Restore"
	echo "0. Exit"
	read -p "Select an option: " OPTION
	
	case $OPTION in
		1)
			backup
			;;
		2)
			restore
			;;
		0)
			echo "Exiting script."
			log "Script exited by user."
			break
			;;
		*)
			echo "Invalid option. Please choose again."
			;;
	esac
done
