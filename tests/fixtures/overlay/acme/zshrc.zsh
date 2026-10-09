# Fixture overlay shell setup; loads after everything else in .zshrc.
(( $+functions[acme_widget] && $+functions[toolbox] )) && ACME_ZSHRC_LAST=1
