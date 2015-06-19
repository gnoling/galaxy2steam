call pp -o galaxy2steam.exe -M JSON::backportPP -M Log::Log4perl -M Math::Int64 -M File::Path -M LWP::UserAgent -M DBI -M DBD::SQLite -M String::Similarity::Group -M Search::Tokenizer -M JSON -M JSON::XS -M Win32::Console::ANSI galaxy2steam.pl
perl -e "use Win32::Exe; $exe = Win32::Exe->new('galaxy2steam.exe'); $exe->set_single_group_icon('galaxy2steam.ico'); $exe->write;"
move /Y galaxy2steam.exe dist/

