int run_wrapper(ParserContext *ctx, FILE *allowlist_fp, const AuditLog *audit,
                const char *workspace) {
    int ret = EXIT_WRAPPER_ERROR;
    char **target_argv = NULL;
    char *exec_path = NULL;
    int target_argc = 0;

    TerminalSize termsize;
    if (parse_header(ctx, &termsize) == -1) return EXIT_WRAPPER_ERROR;
    target_argv = parse_target_args(ctx, &target_argc);
    if (!target_argv) return EXIT_WRAPPER_ERROR;

    const char *why;
    exec_path = resolve_command(target_argv[0], workspace, &why);
    if (!exec_path) {
        log_error("Error: Command '%s' %s\n", target_argv[0],
                  why ? why : "cannot be resolved");
        (void)audit_log(audit, "DENIED ", target_argc, target_argv);
        ret = EXIT_DENIED;
        goto cleanup;
    }

    AllowlistResult allow_res = check_allowed(exec_path, allowlist_fp, workspace);
    if (!allow_res.allowed) {
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

    ret = execute_command_with_pty(exec_path, target_argv, target_argc, termsize,
                                   allow_res.has_stdin);
#else
    (void)audit;
    (void)termsize;
    ret = 0;
#endif

cleanup:
    free(exec_path);
    free_target_args(target_argv, target_argc);
    return ret;
}
