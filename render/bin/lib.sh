#!/bin/bash
# Shared helpers for the per-program start scripts.

# use_env PREFIX: give this program ONLY its own config.
#   PREFIX__KEY=value  ->  KEY=value   (empty values are dropped, so apps fall back to their
#                                       defaults instead of getting "")
#   any other <APP>__* variable (another app's secrets) is removed.
use_env() {
	local prefix="$1" v val
	for v in $(compgen -e); do
		case "$v" in
			"${prefix}"__*)
				val="${!v}"
				unset "$v"
				[ -n "$val" ] && export "${v#"${prefix}"__}=$val"
				;;
			PORTFOLIO__* | EXPENSE__* | DAYLINE__*) unset "$v" ;;
		esac
	done
}

# prefix_output NAME: from here on, every stdout/stderr line is prefixed with "[NAME] ".
# The prefixer dies with the program (EOF), and the program keeps the supervised PID via exec.
prefix_output() {
	exec > >(exec sed -u "s/^/[$1] /") 2>&1
}
