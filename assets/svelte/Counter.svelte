<script lang="ts">
  type CounterProps = {
    initial?: number
  }

  const {initial = 3}: CounterProps = $props()
  let count = $state(0)

  $effect(() => {
    count = initial
  })

  const decrement = () => {
    count = count - 1
  }

  const increment = () => {
    count = count + 1
  }

  const reset = () => {
    count = initial
  }
</script>

<div class="rounded-2xl border border-neutral-200/70 bg-white/80 p-5 shadow-sm backdrop-blur dark:border-neutral-800/70 dark:bg-neutral-950/60">
  <div class="flex items-center justify-between">
    <div>
      <p class="text-xs uppercase tracking-[0.2em] text-neutral-500 dark:text-neutral-400">
        LiveSvelte demo
      </p>
      <h2 class="mt-1 text-lg font-semibold text-neutral-900 dark:text-neutral-50">Counter</h2>
    </div>
    <span class="rounded-full border border-neutral-200/70 px-2 py-1 text-xs text-neutral-600 dark:border-neutral-800 dark:text-neutral-400">
      client only
    </span>
  </div>

  <div class="mt-6 flex items-center gap-4">
    <button
      type="button"
      class="flex h-11 w-11 items-center justify-center rounded-full border border-neutral-200/80 bg-white text-xl font-semibold text-neutral-800 shadow-sm transition duration-200 ease-out hover:-translate-y-0.5 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-neutral-900/30 active:translate-y-0 active:scale-95 dark:border-neutral-700/80 dark:bg-neutral-900 dark:text-neutral-100 dark:focus-visible:ring-neutral-200/30"
      aria-label="Decrement"
      onclick={decrement}
    >
      -
    </button>

    <div
      class="min-w-[3.5rem] rounded-2xl border border-neutral-200/60 bg-white/70 px-4 py-2 text-center text-2xl font-semibold text-neutral-900 shadow-sm dark:border-neutral-800/70 dark:bg-neutral-950/60 dark:text-neutral-50"
      aria-live="polite"
    >
      {count}
    </div>

    <button
      type="button"
      class="flex h-11 w-11 items-center justify-center rounded-full border border-neutral-200/80 bg-white text-xl font-semibold text-neutral-800 shadow-sm transition duration-200 ease-out hover:-translate-y-0.5 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-neutral-900/30 active:translate-y-0 active:scale-95 dark:border-neutral-700/80 dark:bg-neutral-900 dark:text-neutral-100 dark:focus-visible:ring-neutral-200/30"
      aria-label="Increment"
      onclick={increment}
    >
      +
    </button>
  </div>

  <div class="mt-4 flex items-center justify-between text-sm text-neutral-500 dark:text-neutral-400">
    <span>Local state, no server roundtrips.</span>
    <button
      type="button"
      class="rounded-full border border-neutral-200/80 px-3 py-1 font-medium text-neutral-700 transition hover:border-neutral-300 hover:text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-neutral-900/30 active:scale-95 dark:border-neutral-700/80 dark:text-neutral-200 dark:hover:border-neutral-600 dark:hover:text-white dark:focus-visible:ring-neutral-200/30"
      onclick={reset}
    >
      Reset
    </button>
  </div>
</div>
