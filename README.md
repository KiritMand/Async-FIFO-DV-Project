# async_fifo

A parameterized Cummings-style asynchronous FIFO (gray-code pointers, two-flop synchronizers,
registered full/empty), verified with UVM, functional coverage, SVA, SymbiYosys formal
(two clocks, k-induction), planted bugs and MCY mutation coverage.

**Status:** M0 (toolchain and skeleton) in progress. The progress is logged in [docs/progress.md](docs/progress.md).

```bash
make help
```

The reviewer-facing results page arrives in M10.
