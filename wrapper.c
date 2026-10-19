static int run_wrapper(ParserContext *ctx, const Allowlist *allowlist,
                       const AuditLog *audit, const char *workspace) {
    int ret = EXIT_INTERNAL_ERROR;
    char **target_argv = NULL;
    char *exec_path = NULL;
    int target_argc = 0;

    Terminal term;
    if (parse_header(ctx, &term) == -1) return EXIT_INTERNAL_ERROR;
    target_argv = parse_target_args(ctx, &target_argc);
    if (!target_argv) return EXIT_INTERNAL_ERROR;

    const char *why;
    exec_path = resolve_command(target_argv[0], workspace, &why);
    if (!exec_path) {
        log_error("Error: Command '%s' %s\n", target_argv[0],
                  why ? why : "cannot be resolved");
        (void)audit_log(audit, "DENIED ", target_argc, target_argv);
        ret = EXIT_DENIED;
        goto cleanup;
    }

    const AllowlistEntry *entry = find_entry(allowlist, exec_path);
    if (!entry) {
        log_error("Error: Command '%s' not in allowlist\n", target_argv[0]);
        (void)audit_log(audit, "DENIED ", target_argc, target_argv);
        ret = EXIT_DENIED;
        goto cleanup;
    }

    // The entry precedes the command, so a trail that cannot be written is
    // still a command that has not run.
    if (audit_log(audit, "ALLOWED", target_argc, target_argv) == -1) {
        log_error("Error: refusing to run a request that was not recorded\n");
        goto cleanup;
    }

#ifndef FUZZING
    // The target runs in the allowlist directory, so its arguments can name
    // paths relative to it.
    if (chdir(workspace) != 0) {
        log_error("chdir to %s: %s\n", workspace, strerror(errno));
        goto cleanup;
    }

    ret = execute_command(exec_path, target_argv, term, entry->has_stdin,
                          entry->has_pty && term.tty);
#else
    (void)audit;
    (void)term;
    ret = 0;
#endif

cleanup:
    free(exec_path);
    free_target_args(target_argv, target_argc);
    return ret;
}
