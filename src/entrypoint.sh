#!/bin/bash
# Catch termination of container and exit script
trap "exit 0" SIGTERM SIGINT

echo "########################################"
echo "#############   CONFIG   ###############"
echo "########################################"
echo "User and Group: $(id -u):$(id -g)"


# Write user and group ID to the config files
sed -i "s/AnonUser cups/AnonUser $(id -u):$(id -g)/g" /etc/cups/cups-pdf.conf
sed -i "s/Grp cups/Grp $(id -g)/g" /etc/cups/cups-pdf.conf
sed -i "s/Group cups/Group $(id -g)/g" /etc/cups/cups-files.conf
sed -i "s/User cups/User $(id -u)/g" /etc/cups/cups-files.conf


# Write CUPS PDF standard options from environment variables
for cupspdf_option in $(env | grep -e "CUPS_PDF_OPTION_[a-zA-Z0-9]\+=" ) ;
do
    KEY="${cupspdf_option%%=*}"
    VALUE="${cupspdf_option#*=}"
    NAME="${KEY#CUPS_PDF_OPTION_}"
    echo "CUPS PDF overwrite default option $NAME to $VALUE"
    sed -i -r "s/^#?${NAME} .*$/${NAME} ${VALUE}/g" /etc/cups/cups-pdf.conf
done

# Create config files for all requested CUPS PDF instances from environment variables
for cupspdf_instance in $(env | grep -e "CUPS_PDF_INSTANCE[0-9]\+=" ) ;
do
    #NAME="${cupspdf_instance#*=}"
    #KEY="${cupspdf_instance%%=*}"
    NAME="${cupspdf_instance%%_*}"
    KEY="${cupspdf_instance#*_}"
    echo "Configuring $KEY ($NAME)"
    # Copy config file
    cp /etc/cups/cups-pdf.conf "/etc/cups/cups-pdf-${NAME}.conf"
    # Check output directory (standard or overwrite)
    OUTPUT_DIR_VAR="${KEY}_OUTPUTDIR"
    if [ "${!OUTPUT_DIR_VAR}" == "" ] ; then
        echo "    Output directory: $CUPS_PDF_OUT/printout/${KEY}"
        INSTANCE_OUTPUT_DIR="$CUPS_PDF_OUT/printout/${KEY}"
    else
        if [[ ${!OUTPUT_DIR_VAR} =~ ^${CUPS_PDF_OUT}/.* ]] ; then
            echo "    Output directory: ${!OUTPUT_DIR_VAR}"
            INSTANCE_OUTPUT_DIR="${!OUTPUT_DIR_VAR}"
        else
            echo "    ERROR: The output directory of the printers must start with $CUPS_PDF_OUT due to permission requirements, but currently is ${!OUTPUT_DIR_VAR}. This can only be changed at build time in the Dockerfile"
            exit 1
        fi
    fi
    # Create output directory
    mkdir -p "${INSTANCE_OUTPUT_DIR}"
    # Prepare output directory string for sed usage (masking slashes)
    INSTANCE_OUTPUT_DIR=$(sed "s/\//\\\\\//g" <<< "$INSTANCE_OUTPUT_DIR")
    # Replace CUPS PDF options from environment variables
    sed -i "s/Out \/mnt\/printout/Out ${INSTANCE_OUTPUT_DIR}/g" "/etc/cups/cups-pdf-${NAME}.conf"
    sed -i "s/AnonDirName \/mnt\/printout/AnonDirName ${INSTANCE_OUTPUT_DIR}/g" "/etc/cups/cups-pdf-${NAME}.conf"
    for cupspdf_option in $(env | grep -e "${KEY}_OPTION_[a-zA-Z0-9]\+=" ) ;
    do
        KEY="${cupspdf_option%%=*}"
        VALUE="${cupspdf_option#*=}"
        OPTIONNAME="${KEY#CUPS_PDF_INSTANCE*_OPTION_}"
        echo "    CUPS PDF $NAME overwrite option $OPTIONNAME to $VALUE"
        sed -i -r "s/^#?${OPTIONNAME} .*$/${OPTIONNAME} ${VALUE}/g" "/etc/cups/cups-pdf-${NAME}.conf"
    done
    # Create log file for this instance
    touch "/var/log/cups/cups-pdf-${NAME}_log"
done
echo "########################################"

echo "Starting cupsd"
/usr/sbin/cupsd
sleep 1

for cupspdf_instance in $(env | grep -e "CUPS_PDF_INSTANCE[0-9]\+=" ) ;
do
    #NAME="${cupspdf_instance#*=}"
    NAME="${cupspdf_instance%%_*}"
    echo "Adding CUPS PDF printer \"$NAME\""
    lpadmin -p "${NAME}" -E -v "cups-pdf:/${NAME}" -P /etc/cups/ppd/CUPS-PDF_noopt.ppd
done
echo "########################################"

tail -n 1000 -f /var/log/cups/access_log &
tail -n 1000 -f /var/log/cups/error_log &
tail -n 1000 -f /var/log/cups/page_log &
for cupspdf_instance in $(env | grep -e "CUPS_PDF_INSTANCE[0-9]\+=" ) ;
do
    #NAME="${cupspdf_instance#*=}"
    NAME="${cupspdf_instance%%_*}"
    tail -n 1000 -f "/var/log/cups/cups-pdf-${NAME}_log" &
done

while [ 1 == 1 ] ;
do
  : # busy-wait
done
