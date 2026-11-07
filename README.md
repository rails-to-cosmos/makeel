# makeel

Pick a target from the nearest parent Makefile, run it in an interactive
compilation buffer, and switch between tracked runs.

Requires Emacs 29.1 or later, Transient 0.4 or later, and GNU Make on PATH.

## Usage

Run M-x makeel-menu, or bind it:

```elisp
(require 'makeel)
(global-set-key (kbd "C-x y m") #'makeel-menu)
(makeel-mode-line-mode 1) ; optional global status tracking
```

The menu offers `makeel-run` and `makeel-switch-buffer`. During execution,
type responses at the process prompt; C-c C-c interrupts the process and
C-c C-k kills it. Password prompts suppress input echo through comint.
After exit, the buffer becomes read-only: q closes its window, and
compilation navigation, including next-error, remains available.

Mode-line entries show running, successful, and failed targets. Mouse-1
opens the output; mouse-3 removes the buffer after confirmation.
`makeel-mode-line-cleanup-delay` controls how long completed entries remain
(default 60 seconds; nil keeps them indefinitely).

Execution uses a PTY through compilation/comint and supports ANSI colors.
Full-screen terminal programs require a separate terminal. Targets are
discovered from literal rules in Makefile; variable expansion, included
Makefiles, and Make's complete grammar are outside this parser's scope.

## Development

`make check` runs package-lint, byte compilation with warnings as errors,
and ERT. The tests cover target discovery, tracker toggling, PTY input,
failed-process completion, and next-error navigation to a source file.
`make package` and `make install-emacs` use the sibling elpa repository.

## Prior art

`makefile-executor` also
provides Makefile target selection. makeel adds global status tracking and
switching between output buffers. The unrelated
[DamienCassou/makel](https://github.com/DamienCassou/makel) is a Makefile
lint harness.

## License

See LICENSE.
