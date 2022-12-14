#!/usr/bin/env bash
#
# test_buildah_build_rpm.sh
#
# Meant to run on a freshly installed VM.
# Installs the latest Git and Buildah and then
# Builds and installs Buildah's RPM in a Buildah Container.
# The baseline test is then run on this vm and then the
# newly created BUILDAH rpm is installed and the baseline
# test is rerun.
# 

########
# Setup
########
IMAGE=registry.fedoraproject.org/fedora
SBOX=/tmp/sandbox
PACKAGES=/tmp/packages
mkdir -p ${SBOX}/buildah
GITROOT=${SBOX}/buildah
TEST_SOURCES=${GITROOT}/tests

# Change packager as appropriate for the platform
PACKAGER=dnf

${PACKAGER} install -y git
${PACKAGER} install -y buildah

########
# Clone buildah from GitHub.com
########
cd $SBOX
git clone https://github.com/containers/buildah.git
cd $GITROOT

########
# Build a container to use for building the binaries.
########
CTRID=$(buildah from --pull --signature-policy ${TEST_SOURCES}/policy.json $IMAGE)
ROOTMNT=$(buildah mount $CTRID)
COMMIT=$(git log --format=%H -n 1)
SHORTCOMMIT=$(echo ${COMMIT} | cut -c-7)
mkdir -p ${ROOTMNT}/rpmbuild/{SOURCES,SPECS}

########
# Build the tarball.
########
(git archive --format tar.gz --prefix=buildah-${COMMIT}/ ${COMMIT}) > ${ROOTMNT}/rpmbuild/SOURCES/buildah-${SHORTCOMMIT}.tar.gz

########
# Update the .spec file with the commit ID.
########
sed s:REPLACEWITHCOMMITID:${COMMIT}:g ${GITROOT}/contrib/rpm/buildah.spec > ${ROOTMNT}/rpmbuild/SPECS/buildah.spec

########
# Install build dependencies and build binary packages.
########
buildah run $CTRID -- dnf -y install 'dnf-command(builddep)' rpm-build
buildah run $CTRID -- dnf -y builddep --spec /rpmbuild/SPECS/buildah.spec
buildah run $CTRID -- rpmbuild --define "_topdir /rpmbuild" -ba /rpmbuild/SPECS/buildah.spec

########
# Build a second new container.
########
CTRID2=$(buildah from --pull --signature-policy ${TEST_SOURCES}/policy.json $IMAGE)
ROOTMNT2=$(buildah mount $CTRID2)

########
# Copy the binary packages from the first container to the second one and to 
# /tmp.  Also build a list of their filenames.
########
rpms=
mkdir -p ${ROOTMNT2}/${PACKAGES}
mkdir -p ${PACKAGES} 
for rpm in ${ROOTMNT}/rpmbuild/RPMS/*/*.rpm ; do
	cp $rpm ${ROOTMNT2}/${PACKAGES}
	cp $rpm ${PACKAGES} 
	rpms="$rpms "${PACKAGES}/$(basename $rpm)
done

########
# Install the binary packages into the second container.
########
buildah run $CTRID2 -- dnf -y install $rpms

########
# Run the binary package and compare its self-identified version to the one we tried to build.
########
id=$(buildah run $CTRID2 -- buildah version | awk '/^Git Commit:/ { print $NF }')
bv=$(buildah run $CTRID2 -- buildah version | awk '/^Version:/ { print $NF }')
rv=$(buildah run $CTRID2 -- rpm -q --queryformat '%{version}' buildah)
echo "short commit: $SHORTCOMMIT"
echo "id: $id"
echo "buildah version: $bv"
echo "buildah rpm version: $rv"
test $SHORTCOMMIT = $id
test $bv = $rv

########
# Clean up Buildah
########
buildah rm $(buildah containers -q)
buildah rmi -f $(buildah images -q)

########
# Kick off baseline testing against the installed Buildah 
########
/bin/bash -v ${TEST_SOURCES}/test_buildah_baseline.sh

########
# Install the Buildah we just built locally and run 
# the baseline tests again.
########
${PACKAGER} -y install ${PACKAGES}/*.rpm
/bin/bash -v ${TEST_SOURCES}/test_buildah_baseline.sh

########
# Clean up 
########
rm -rf ${SBOX}
rm -rf ${PACKAGES}
buildah rm $(buildah containers -q)
buildah rmi -f $(buildah images -q)
${PACKAGER} remove -y buildah
