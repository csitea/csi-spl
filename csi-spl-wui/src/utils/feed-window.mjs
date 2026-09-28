/** One page of a feed: the first paint and every Load more. Its own module so
    a plugin that needs the number (plugins/lobby-warm) does not pull the live
    store into the entry chunk. */
export const WINDOW = 30
