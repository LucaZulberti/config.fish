# Prepare environment to use Java from brew on Mac OS
if type -q brew
    set prefix (brew --prefix openjdk)
    if test -n "$prefix"
        set -x JAVA_HOME $prefix/libexec/openjdk.jdk/Contents/Home
        fish_add_path $JAVA_HOME/bin
    end
end
