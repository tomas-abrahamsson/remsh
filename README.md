For connecting to an Erlang node using `erl -remsh` from within Emacs.

Remsh provides a way to use `erl -remsh` to connect to an already
running Erlang node, from within Emacs, as an inferior Erlang shell.

Use `M-x remsh-connect` to connect.

Once connected, `C-c s` will set the remsh-connected inferior Erlang shell
as the buffer to use when compiling Erlang code from within Emacs.
This is compiling and hot-loading code directly from Emacs
into a running node.

If the connection is broken for some reason or the Erlang node is
restarted, `C-c r` will attempt to reconnect.

Dependencies (available via [elpa](https://elpa.gnu.org/) or
[melpa](https://melpa.org/)):

* [transient](https://elpa.gnu.org/packages/transient.html)
* [dash](https://github.com/magnars/dash.el)
* [s](https://github.com/magnars/s.el) (via [melpa](https://melpa.org/))
* [erlang](https://melpa.org/#/erlang) see also [erlang/otp on github](https://github.com/erlang/otp/tree/master/lib/tools/emacs)

Use for example `M-x package-install <pkg>` to install them.  Refer to
[melpa getting started](https://melpa.org/#/getting-started) for
info on how to set up your Emacs to access packages from melpa.
