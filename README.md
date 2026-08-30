# hackernews_filter

A source filter for **[EmergenceSystem](https://github.com/EmergenceSystem)**, a distributed
discovery network of small agents. It joins the em_pop gossip mesh and answers
`POST /agent/query`: it searches Hacker News stories via the Algolia HN API, returned as embryos (title, url, short summary).

Emquest fans a query out to many such filters in parallel and aggregates the results,
so each filter stays small and focused on a single source.

## Run

```sh
rebar3 shell
```

Built on [em_filter](https://github.com/EmergenceSystem/em_filter). Apache-2.0.
