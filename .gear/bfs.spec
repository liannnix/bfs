%define _unpackaged_files_terminate_build 1

Name: bfs
Version: 2023.08
Release: alt1.git15ce658
Summary: bfs is a variant of the UNIX find
License: 0BSD
Group: Development/Other
Url: https://github.com/tavianator/bfs
Source: %name-%version.tar

BuildRequires(pre): rpm-macros-cmake make cmake gcc 
BuildRequires(pre): liboniguruma-devel acl libacl libacl-devel  
BuildRequires(pre): libcap libcap-devel attr libattr libattr-devel libattr-devel-static
# Require for tests
BuildRequires(pre): /proc

%description
bfs is a variant of the UNIX find command that operates breadth-first rather than depth-first. It is otherwise compatible with many versions of find, including POSIX, GNU, FreeBSD, OpenBSD, NetBSD, macOS.

%prep
%setup

%build
%make_build 

%install
%makeinstall_std

%check
%make_build check

%files
%_bindir/*
%doc README.md docs/*.md
%_man1dir/*
%_datadir/zsh/site-functions/*
%_datadir/fish/vendor_completions.d/*
%_datadir/bash-completion/completions/*


%changelog
* Mon Aug 21 2023 Anton Protopopov <antpro@altlinux.org> 2023.08-alt1.git15ce658
- Initial package


