#/bin/sh

# Set the has_failed variable to false. This will change if any of the subsequent database backups/uploads fail.
has_failed=false

echo "Create the GCloud Authentication file if set"
if [ ! -z "$GCP_GCLOUD_AUTH" ]; then

    # Check if we are already base64 decoded, credit: https://stackoverflow.com/questions/8571501/how-to-check-whether-a-string-is-base64-encoded-or-not
    if echo "$GCP_GCLOUD_AUTH" | grep -Eq '^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)?$'; then
        echo "$GCP_GCLOUD_AUTH" | base64 --decode >"$HOME"/gcloud.json
    else
        echo "$GCP_GCLOUD_AUTH" >"$HOME"/gcloud.json
    fi

    # Activate the Service Account
    echo "Activating Google cloud services"
    gcloud auth activate-service-account --key-file=$HOME/gcloud.json

fi

echo "Set the BACKUP_CREATE_DATABASE_STATEMENT variable"
if [ "$BACKUP_CREATE_DATABASE_STATEMENT" = "true" ]; then
    BACKUP_CREATE_DATABASE_STATEMENT="--databases"
else
    BACKUP_CREATE_DATABASE_STATEMENT=""
fi

if [ "$TARGET_ALL_DATABASES" = "true" ]; then
    ALL_DATABASES_EXCLUSION_LIST="'mysql','sys','tmp','information_schema','performance_schema'"
    ALL_DATABASES_SQLSTMT="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (${ALL_DATABASES_EXCLUSION_LIST})"
    if ! ALL_DATABASES_DATABASE_LIST=`mysql -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT -ANe"${ALL_DATABASES_SQLSTMT}"`
    then
        echo -e "Building list of all databases failed at $(date +'%d-%m-%Y %H:%M:%S')." | tee -a /tmp/kubernetes-cloud-mysql-backup.log
        has_failed=true
    fi
    if [ "$has_failed" = false ]; then
        for DB in ${ALL_DATABASES_DATABASE_LIST}
        do
            TARGET_DATABASE_NAMES="${TARGET_DATABASE_NAMES}${DB},"
        done
        #Remove trailing comma
        TARGET_DATABASE_NAMES=${TARGET_DATABASE_NAMES%?}
        echo -e "Successfully built list of all databases (${TARGET_DATABASE_NAMES}) at $(date +'%d-%m-%Y %H:%M:%S')."
    fi
fi

echo "Loop through all the defined databases, seperating by a ,"
echo -e "TARGET_DATABASE_NAMES is ($TARGET_DATABASE_NAMES)"
if [ "$has_failed" = false ]; then
    while [ "$TARGET_DATABASE_NAMES" ] ;do
        # extract the substring from start of string up to delimiter.
        # this is the first "element" of the string.
        CURRENT_DATABASE=${TARGET_DATABASE_NAMES%%,*}
        echo "> [$CURRENT_DATABASE]"
        echo "Current database is $CURRENT_DATABASE"
        # if there's only one element left, set `IN` to an empty string.
        # this causes us to exit this `while` loop.
        # else, we delete the first "element" of the string from IN, and move onto the next.
        [ "$TARGET_DATABASE_NAMES" = "$CURRENT_DATABASE" ] && \
        TARGET_DATABASE_NAMES='' || \
        TARGET_DATABASE_NAMES="${TARGET_DATABASE_NAMES#*;}"

        if  [ "$NO_DB_NAME" = "true" ]; then
            DUMP=backup$(date +$BACKUP_TIMESTAMP).sql
        else
            DUMP=$CURRENT_DATABASE$(date +$BACKUP_TIMESTAMP).sql
        fi
        echo "Perform the database backup. Put the output to a variable. If successful upload the backup to S3, if unsuccessful print an entry to the console and the log, and set has_failed to true."
        if sqloutput=$(mysqldump --column-statistics=0 -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT $CURRENT_DATABASE 2>&1 >/tmp/$DUMP); then

            echo -e "Database backup successfully completed for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."

            # Convert BACKUP_COMPRESS to lowercase before executing if statement
            BACKUP_COMPRESS=$(echo "$BACKUP_COMPRESS" | awk '{print tolower($0)}')

            # If the Backup Compress is true, then compress the file for .gz format
            if [ "$BACKUP_COMPRESS" = "true" ]; then
                if [ -z "$BACKUP_COMPRESS_LEVEL" ]; then
                    BACKUP_COMPRESS_LEVEL="9"
                fi
                gzip -${BACKUP_COMPRESS_LEVEL} -c /tmp/"$DUMP" >/tmp/"$DUMP".gz
                rm /tmp/"$DUMP"
                DUMP="$DUMP".gz
            fi

            # Optionally encrypt the backup
            if [ -n "$AGE_PUBLIC_KEY" ]; then
                cat /tmp/"$DUMP" | age -a -r "$AGE_PUBLIC_KEY" >/tmp/"$DUMP".age
                echo -e "Encrypted backup with age"
                rm /tmp/"$DUMP"
                DUMP="$DUMP".age
            fi

            # Convert BACKUP_PROVIDER to lowercase before executing if statement
            BACKUP_PROVIDER=$(echo "$BACKUP_PROVIDER" | awk '{print tolower($0)}')

            echo "If the Backup Provider is AWS, then upload to S3"
            if [ "$BACKUP_PROVIDER" = "aws" ]; then

                # If the AWS_S3_ENDPOINT variable isn't empty, then populate the --endpoint-url parameter to use a custom S3 compatable endpoint
                if [ ! -z "$AWS_S3_ENDPOINT" ]; then
                    ENDPOINT="--endpoint-url=$AWS_S3_ENDPOINT"
                fi

                # Perform the upload to S3. Put the output to a variable. If successful, print an entry to the console and the log. If unsuccessful, set has_failed to true and print an entry to the console and the log
                if awsoutput=$(aws $ENDPOINT s3 cp /tmp/$DUMP s3://$AWS_BUCKET_NAME$AWS_BUCKET_BACKUP_PATH/$DUMP 2>&1); then
                    echo -e "Database backup successfully uploaded for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."
                else
                    echo -e "Database backup failed to upload for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). Error: $awsoutput" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
                    has_failed=true
                fi
                rm /tmp/"$DUMP"

                if [ "$DB_CLEANUP" = "true" ]; then
                    NUM_BACKUPS=`aws s3 ls "${AWS_BUCKET_NAME}${AWS_BUCKET_BACKUP_PATH}/" | grep "\.sql" | wc -l`;
                    echo "Checking backup status for ${AWS_BUCKET_NAME}${AWS_BUCKET_BACKUP_PATH}/";
                    echo "Current number of backups : $NUM_BACKUPS max is $MAX_NUMBER_OF_BACKUPS";
                    while [ $NUM_BACKUPS -gt $MAX_NUMBER_OF_BACKUPS ];
                    do
                        CURRENT_BACKUP_TO_DELETE=`aws s3 ls ${AWS_BUCKET_NAME}${AWS_BUCKET_BACKUP_PATH}/ | grep "\.sql" | awk '{print $4}' | sed -n 1p`;
                        echo "SHOULD DELETE $CURRENT_BACKUP_TO_DELETE.";
                        aws s3 rm s3://${AWS_BUCKET_NAME}${AWS_BUCKET_BACKUP_PATH}/$CURRENT_BACKUP_TO_DELETE;
                        NUM_BACKUPS=`aws s3 ls "${AWS_BUCKET_NAME}${AWS_BUCKET_BACKUP_PATH}/" | grep "\.sql" | wc -l`;
                        echo "New number of backups : $NUM_BACKUPS max is $MAX_NUMBER_OF_BACKUPS";
                    done;
                fi
            fi

            # If the Backup Provider is GCP, then upload to GCS
            if [ "$BACKUP_PROVIDER" = "gcp" ]; then

                # Perform the upload to S3. Put the output to a variable. If successful, print an entry to the console and the log. If unsuccessful, set has_failed to true and print an entry to the console and the log
                if gcpoutput=$(gsutil cp /tmp/$DUMP gs://$GCP_BUCKET_NAME$GCP_BUCKET_BACKUP_PATH/$DUMP 2>&1); then
                    echo -e "Database backup successfully uploaded for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."
                else
                    echo -e "Database backup failed to upload for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). Error: $gcpoutput" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
                    has_failed=true
                fi
                rm /tmp/"$DUMP"

                if [ "$DB_CLEANUP" = "true" ]; then
                    NUM_BACKUPS=`gsutil ls gs://"${GCP_BUCKET_NAME}${GCP_BUCKET_BACKUP_PATH}/" | grep "\.sql" | wc -l`;
                    echo "Checking backup status for ${GCP_BUCKET_NAME}${GCP_BUCKET_BACKUP_PATH}/";
                    echo "Current number of backups : $NUM_BACKUPS max is $MAX_NUMBER_OF_BACKUPS";
                    while [ $NUM_BACKUPS -gt $MAX_NUMBER_OF_BACKUPS ];
                    do
                        CURRENT_BACKUP_TO_DELETE=`gsutil ls gs://${GCP_BUCKET_NAME}${GCP_BUCKET_BACKUP_PATH}/ | grep "\.sql" | sed -n 1p`;
                        echo "SHOULD DELETE $CURRENT_BACKUP_TO_DELETE";
                        gsutil rm $CURRENT_BACKUP_TO_DELETE;
                        NUM_BACKUPS=`gsutil ls gs://"${GCP_BUCKET_NAME}${GCP_BUCKET_BACKUP_PATH}/"| grep "\.sql" | wc -l`;
                        echo "New number of backups : $NUM_BACKUPS max is $MAX_NUMBER_OF_BACKUPS";
                    done;
                fi
            fi
        else
            echo -e "Database backup FAILED for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). Error: $sqloutput" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
            has_failed=true
            if [ "$IGNORE_ERRORS" = "true" ]; then
              has_failed=false
            fi
        fi
    done
fi

# Check if any of the backups have failed. If so, exit with a status of 1. Otherwise exit cleanly with a status of 0.
if [ "$has_failed" = true ]; then

    # Convert SLACK_ENABLED to lowercase before executing if statement
    SLACK_ENABLED=$(echo "$SLACK_ENABLED" | awk '{print tolower($0)}')

    # If Slack alerts are enabled, send a notification alongside a log of what failed
    if [ "$SLACK_ENABLED" = "true" ]; then
        # Put the contents of the database backup logs into a variable
        logcontents=$(cat /tmp/kubernetes-cloud-mysql-backup.log)

        # Send Slack alert
        /slack-alert.sh "One or more backups on database host $TARGET_DATABASE_HOST failed. The error details are included below:" "$logcontents"
    fi

    echo -e "kubernetes-cloud-mysql-backup encountered 1 or more errors. Exiting with status code 1."
    exit 1

else

    # If Slack alerts are enabled, send a notification that all database backups were successful
    if [ "$SLACK_ENABLED" = "true" ]; then
        /slack-alert.sh "All database backups successfully completed on database host $TARGET_DATABASE_HOST."
    fi

    exit 0

fi
