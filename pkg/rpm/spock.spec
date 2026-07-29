%global pname spock
%global sname pgedge-spock%{spockmajorversion}
%global pginstdir /usr/pgsql-%{pgmajorversion}

%{!?llvm:%global llvm 1}

Name:		%{sname}_%{pgmajorversion}
Version:	%{spock_version}
Release:	%{spock_buildnum}%{?dist}
Summary:	Logical Multi-master Replication 
License:	PostgreSQL License
URL:		https://github.com/pgEdge/%{pname}/
Source0:	spock-%{version}.tar.gz

BuildRequires:	pgedge-postgresql%{pgmajorversion}-devel
BuildRequires:	lz4-devel krb5-devel e2fsprogs-devel openssl-devel jansson-devel
BuildRequires:	libxml2-devel libxslt-devel pam-devel libzstd-devel >= 1.4.0
Requires:	pgedge-postgresql%{pgmajorversion}-server jansson
Provides:       %{pname}%{spockmajorversion}_%{pgmajorversion}
Conflicts:      pgedge-spock50_%{pgmajorversion}

%description
This SPOCK extension provides multi-master replication for PostgreSQL 15+. We
originally leveraged the pgLogical and BDR2 projects as a solid foundation to
build upon for this enterprise-class extension.

%if %llvm
%package llvmjit
Summary:	Just-in-time compilation support for spock
Requires:	%{name}%{?_isa} = %{version}-%{release}
%if 0%{?suse_version} >= 1500
BuildRequires:	llvm17-devel clang17-devel
Requires:	llvm17
%endif
%if 0%{?fedora} || 0%{?rhel} >= 8
BuildRequires:	llvm-devel >= 13.0 clang-devel >= 13.0
Requires:	llvm => 13.0
Provides:       %{pname}%{spockmajorversion}_%{pgmajorversion}-llvmjit
%endif

%description llvmjit
This packages provides JIT support for spock
%endif

%prep
%setup -q -n %{pname}-%{version}

%build
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} #%{?_smp_mflags}
syft dir:%{_builddir}/%{pname}-%{version} -o cyclonedx-json > %{_builddir}/%{pname}-%{version}/%{pname}%{spockmajorversion}-sbom.json || exit 1

KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5}' | head -n 1); export KEY_ID
gpg --armor --detach-sign --output %{_builddir}/%{pname}-%{version}/%{pname}%{spockmajorversion}-sbom.json.asc %{_builddir}/%{pname}-%{version}/%{pname}%{spockmajorversion}-sbom.json || exit 1

%install
%{__rm} -rf %{buildroot}
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} %{?_smp_mflags} install DESTDIR=%{buildroot}

mkdir -p %{buildroot}/%{pginstdir}/sbom
install -p -m 0644 %{_builddir}/%{pname}-%{version}/%{pname}%{spockmajorversion}-sbom.json %{buildroot}/%{pginstdir}/sbom/%{pname}%{spockmajorversion}-sbom.json
install -p -m 0644 %{_builddir}/%{pname}-%{version}/%{pname}%{spockmajorversion}-sbom.json.asc %{buildroot}/%{pginstdir}/sbom/%{pname}%{spockmajorversion}-sbom.json.asc

%files
%doc README.md
%license LICENSE.md

%{pginstdir}/lib/%{pname}.so
%{pginstdir}/lib/%{pname}_output.so
%{pginstdir}/share/extension/%{pname}.control
%{pginstdir}/share/extension/%{pname}*sql
#%%{pginstdir}/bin/spockctrl
#%%{pginstdir}/share/spock/spockctrl.json
#%%{pginstdir}/share/spock/workflows/add_node.json
#%%{pginstdir}/share/spock/workflows/add_4th_node.json
#%%{pginstdir}/share/spock/workflows/remove_node.json
%{pginstdir}/sbom/%{pname}%{spockmajorversion}-sbom.json
%{pginstdir}/sbom/%{pname}%{spockmajorversion}-sbom.json.asc

%if %llvm
%files llvmjit
   %{pginstdir}/lib/bitcode/%{pname}*.bc
   %{pginstdir}/lib/bitcode/%{pname}/src/*.bc
   %{pginstdir}/lib/bitcode/%{pname}/src/compat/%{pgmajorversion}/*.bc
   %{pginstdir}/lib/bitcode/%{pname}_output/*.bc
%endif

%changelog
* Wed Jul 01 2026 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 6.0.0-beta1
- Initial spock package of 6.0.0-beta1
