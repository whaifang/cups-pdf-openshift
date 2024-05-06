# CUPS-PDF for Openshift

Since CUPS-PDF needs to run as root user, which is considered a huge security risk in Openshift, I changed its code at a few points to make it usable with an arbitrary user.

This relies on the CUPS-PDF version 3.0.1 from 2017-02-24.

## How to build this image
On Openshift you can use this BuildConfig as a starting point and change it for your environment:

```
kind: BuildConfig
apiVersion: build.openshift.io/v1
metadata:
  name: cups-pdf-test
spec:
  source:
    git:
	  # Replace with your own git repo, if you cannot reach github
      uri: 'https://github.com/oooNil/cups-pdf-openshift.git'
	# If you need credentials to pull your git repo, provide a source secret with the credentials
    #sourceSecret:
    #  name: my-git-credentials-secret
  output:
    to:
      kind: ImageStreamTag
      name: 'cups-pdf:latest'
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: 'Dockerfile'
  runPolicy: Serial
```

Note: You need to create the ImageStreamTag cups-pdf:latest to push the image to.

For building with Docker run

```
docker build -t cups-pdf:latest .
```

### How the build works

A multistage build is used:

1. **Stage 1:** The CUPS-PDF executable is compiled from source. The source was changed to enable it running on Openshift (see below). Centos Stream 8 is used as base image, because it has the needed cups-devel package available (in contrast to UBI).
2. **Stage 2:** This is a customized version of the official CUPS Dockerfile with UBI 8.6 as baseimage. The compiled executable from the first stage and the config files from this repository are copied to the image.
    - The entrypoint is placed in /opt/cups.
    - All involved directories have the group set to root (GID 0), so that the user created by Openshift for this container (UID random, GID 0) is capable of reading and writing.
    - The USER directive sets a standard user, so that this container can also run with Docker.
    - The entrypoint script first sets the UID and GID for CUPS and CUPS-PDF in the corresponding config files.
	- The default CUPS-PDF options from the environment variables are written.
	- The individual CUPS-PDF instances are configured with their instance specific options and the default options, creating the output directories and creating the instances log file.

The resulting container uses the arbitrary user from Openshift (or a UID of 1000 and GID of 0 for Docker). Generated PDF files are placed in the
directory /mnt/printout. A persistent volume can be mounted here. The webinterface is reachable
on port 6631.

## How to run this image
On Openshift you can start off this Deployment. If you need to save the generated PDFs persistent, you can mount a persitent volume to /mnt/printout in the container.

```
kind: Deployment
apiVersion: apps/v1
metadata:
  name: cups-pdf-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cups-pdf-test
  template:
    metadata:
      labels:
        app: cups-pdf-test
    spec:
      containers:
        - name: cups-pdf-test
		  # Replace image with your build image
          image: >-
		    image-registry.openshift-image-registry.svc:5000/default/cups-pdf:latest
          ports:
            - containerPort: 6631
              protocol: TCP
          env:
            - name: CUPS_PDF_INSTANCE1
              value: cups-pdf-instance1
            - name: CUPS_PDF_INSTANCE2
              value: cups-pdf-instance2
          imagePullPolicy: Always
      restartPolicy: Always
```

For Docker:

```
# Run bare bone
docker run --name cups-pdf cups-pdf

# Run exposing port and mount host folder for PDF output
docker run -p 6631:6631 -v ~/pdfoutput:/mnt/printout/ --name cups-pdf cups-pdf

# Create 2 CUPS-PDF printers
docker run -e "CUPS_PDF_INSTANCE1=CupsPDFInstance1" -e "CUPS_PDF_INSTANCE2=CupsPDFInstance2" --name cups-pdf cups-pdf
```

For Docker-Compose:

```
version: '3.6'

services:
    cups-pdf:
        restart: always
        build:
            context: .
            dockerfile: docker/Dockerfile
        container_name: cups-pdf
        image: cups-pdf:latest
        volumes:
            - ./pdfoutput:/mnt/printout
        ports:
            - '6631:6631'
```

## Configuring the image
This container can be configured through environment variables:

- `CUPS_PDF_INSTANCEn`: To create multiple CUPS PDF instances inside this CUPS set these environment variables, where `n` should be a number. The value of the variable is the name of the instance. Default: `CUPS_PDF_INSTANCE1=cups-pdf`
- `CUPS_PDF_INSTANCEn_OUTPUTDIR`: Sets the output directory for this CUPS PDF printer instance denominated by the number at `n`. This directory must lie under `/mnt` (set by `ENV CUPS_PDF_OUT=/mnt` in the Dockerfile) due to permission requirements at build time.
Default: `/mnt/printout/InstanceName` (where `InstanceName` is the name of the printer instance)
- `CUPS_PDF_INSTANCEn_OPTION_OptionName`: Set any CUPS PDF config option (in cups-pdf.conf). Replace `n` with the number of the instance to configure and `OptionName` with the exact name of the option to change. ATTENTION: Do NOT overwrite the options `Out` and `AnonDir` with these variables. Instead use the option `CUPS_PDF_INSTANCEn_OUTPUTDIR` to set the output directory. Otherwise you will run into permission problems.
- `CUPS_PDF_OPTION_OptionName`: Similar to the instance specific option, this can set the default CUPS PDF configuration. The instance specific options will take precedence before these options, thus are used if this option is not overwritten by an instance specific variable.

## Changes to Cups-PDF source code

To run Cups-PDF in an Openshift container some changes in the source code of Cups-PDF had to be done. All changes are done in the file cups-pdf.c

- Remove the following code snippet from the start of the `main()` function (Line 825 in original code). Otherwise Cups-PDF will refuse to run as a non-root user:

    if (setuid(0)) {
      (void) fputs("CUPS-PDF cannot be called without root privileges!\n", stderr);
      return 0;
    }

- Add the following code snippet directly before `if (passwd == NULL) {if (strlen(Conf_AnonUser)) {` (Line 860 in original code). It prepares the passwd struct for setting an AnonUser without name (only with IDs):

    //Prepare passwd entry struct for the AnonUser in case, that a UID was provided instead of a username
    struct passwd anonuser_passwd = {
      Conf_AnonUser,
      "",
      atoi(Conf_AnonUser),
      atoi(Conf_AnonUser),
      "",
      "",
      ""};

- Below the above snippet inside of `if (passwd == NULL) {if (strlen(Conf_AnonUser)) {` replace the code until the following `if (passwd == NULL) {` (Line 862 in original code) with the following snippet. This will set the passwd struct with user information based of if it is a user ID, a combination of user and group ID or a username.

    if(strchr(Conf_AnonUser, ':')){
      //AnonUser contains : so it is a uid:gid combination
      char anonuser_string[strlen(Conf_AnonUser)];
      strcpy(anonuser_string, Conf_AnonUser);
      anonuser_passwd.pw_uid = atoi(strtok(anonuser_string, ":"));
      anonuser_passwd.pw_gid = atoi(strtok(NULL, ":"));
      passwd=&anonuser_passwd;
    } else if(isdigit(Conf_AnonUser[0])){
      //AnonUser does not contain : but starts with a digit, so it probably is a uid, gid being the same
      passwd=&anonuser_passwd;
    } else {
      //AnonUser is a username
      passwd=getpwnam(Conf_AnonUser);
    }

- Inside the `main()` function and the `if (!pid) {` statement prepent the line `if (setgroups(ngroups, groups))` (line 1042 in original code) with the following snippet. This prevents setting supplementary groups when the user is not a system user, since in that case there are no supplementary groups to set.

    if (ngroups == 1 && groups[0] == 0)
      log_event(CPDEBUG, "Not setting supplementary groups, because user is not system user");
    else

- In the `init()` function add the following snippet after the line `group=getgrnam(Conf_Grp);` (Line 376 in original code). It will create the group ID struct in the case, that only a GID is provided, not a name of a system group.

    struct group gid_group = {
      Conf_Grp,
      "",
      atoi(Conf_Grp),
      NULL};
    if(!group && isdigit(Conf_Grp[0])){
      group = &gid_group;
    }

While the first change in this list makes sure, that Cups-PDF allows users different from root, the other changes enable us to provide user and group IDs instead of names of system users and groups. This is necessary, since a container in Openshift will run with a random user ID, which is unknown to the passwd file in the container. This user can then be provided to the cups-pdf.conf file by the entrypoint script of the container.
