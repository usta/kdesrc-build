use 5.014;
use Test::More import => ['!note'];

use_ok(qw(ksb::Application));
use_ok(qw(ksb::BuildContext));
use_ok(qw(ksb::BuildException));
use_ok(qw(ksb::BuildSystem::Autotools));
use_ok(qw(ksb::BuildSystem::CMakeBootstrap));
use_ok(qw(ksb::BuildSystem::KDE4));
use_ok(qw(ksb::BuildSystem::QMake));
use_ok(qw(ksb::BuildSystem::Qt4));
use_ok(qw(ksb::BuildSystem));
use_ok(qw(ksb::Debug));
use_ok(qw(ksb::DependencyResolver));
use_ok(qw(ksb::IPC::Null));
use_ok(qw(ksb::IPC::Pipe));
use_ok(qw(ksb::IPC));
use_ok(qw(ksb::KDEProjectsReader));
use_ok(qw(ksb::Module::BranchGroupResolver));
use_ok(qw(ksb::Module));
use_ok(qw(ksb::ModuleResolver));
use_ok(qw(ksb::ModuleSet::KDEProjects));
use_ok(qw(ksb::ModuleSet::Null));
use_ok(qw(ksb::ModuleSet));
#use_ok(qw(ksb::ModuleStatusAnnouncer));
use_ok(qw(ksb::OptionsBase));
use_ok(qw(ksb::PhaseList));
use_ok(qw(ksb::RecursiveFH));
use_ok(qw(ksb::StatusView));
use_ok(qw(ksb::Updater::Bzr));
use_ok(qw(ksb::Updater::Git));
use_ok(qw(ksb::Updater::KDEProject));
use_ok(qw(ksb::Updater::KDEProjectMetadata));
use_ok(qw(ksb::Updater::Svn));
use_ok(qw(ksb::Updater));
use_ok(qw(ksb::Util));
use_ok(qw(ksb::Version));
use_ok(qw(ksb::l10nSystem));

done_testing();