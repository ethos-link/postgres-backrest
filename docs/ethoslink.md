# EthosLink products and open source

[EthosLink](https://www.ethos-link.com) builds business products and publishes engineering tools. This PostgreSQL image comes from database operations work for Reviato; the wider portfolio covers customer feedback, social publishing, retail analysis, and tools for developers.

[Back to the PostgreSQL image README](../README.md) · [Product directory](https://www.ethos-link.com/products) · [Open-source project notes](https://www.ethos-link.com/opensource) · [GitHub organization](https://github.com/ethos-link)

## Products

### Reviato — hear what customers are telling you

For hospitality operators and other local businesses, Reviato brings private customer feedback and public review analysis together. Explore recurring themes in reviews from Google Maps, Tripadvisor, Booking.com, and Airbnb, then inspect the original words behind the findings. Optional contact details and follow-up consent stay attached to private feedback so your team can decide how to respond.

[Explore Reviato](https://www.reviato.com) · [Try the review analysis demo](https://www.reviato.com/pages/features/review-highlights#demo-reviews)

### Nuntio — get social posts ready before they are due

Nuntio gives small businesses a shared workspace for the work before and after a post goes live. Bring your own words and media, adapt each channel's version, ask teammates to review it, and choose a publishing time for each destination. Check delivery outcomes when posts are due; approval and scheduling are separate steps.

[Explore Nuntio](https://www.nuntiohq.com) · [Publishing features](https://www.nuntiohq.com/features) · [Plans](https://www.nuntiohq.com/pricing) · [Guides](https://www.nuntiohq.com/guides) · [Roadmap](https://www.nuntiohq.com/roadmap)

### Profix — understand profit and the stock behind it

Built for clothing shops and boutiques, Profix connects sales and stock records. Review CSV data before importing, compare gross profit excluding VAT by brand or product, and inspect remaining stock and slow movers. It helps shop owners see both what a sale earned and what value remains on the shelves.

**Profix is in early access.** Visit the product page to enquire about your shop, your data, and what participation would involve.

[Explore Profix and ask about early access](https://www.ethos-link.com/products/profix)

## Open-source projects

### postgres-backrest — PostgreSQL with backup tooling included

Run PostgreSQL with PgBackRest preinstalled, WAL archiving defaults, and support for mounted PostgreSQL configuration and PgBackRest templates. Supply your backup repository configuration to fit your environment. Images support `linux/amd64` and `linux/arm64`.

[Setup and configuration](../README.md#quickstart) · [Source and issues](https://github.com/ethos-link/postgres-backrest) · [Docker Hub](https://hub.docker.com/r/ethoslink/postgres-backrest)

### git-markdown — keep the whole pull request in one file

Export GitHub pull request metadata, descriptions, reviews, and discussion into a single Markdown file. Review the conversation offline, share context in an engineering handoff, or pass it to local AI tools. Review comments stay grouped by file and line number.

[Source, installation, and usage](https://github.com/ethos-link/git-markdown) · [Project notes](https://www.ethos-link.com/opensource/git-markdown)

### indexmap — keep sitemap rules in Ruby

Generate XML sitemaps from explicit Ruby entries and sections. Use a single sitemap for a small site or an index and child sitemaps for a larger app. Generated files are staged, formatted, and validated before replacing the published files, so a failed run leaves the previous sitemap in place. Rails tasks handle generation and validation.

[Source, installation, and usage](https://github.com/ethos-link/indexmap) · [Project notes](https://www.ethos-link.com/opensource/indexmap)

### Crawlscope — turn SEO checks into repeatable validation

Crawl the URLs in a sitemap to check indexability, titles, descriptions, canonical links, JSON-LD, and internal links. Run from Ruby, the command line, or Rails tasks. Findings include a code, severity, URL, and supporting details so automation can act on structured results.

[Source, installation, and usage](https://github.com/ethos-link/crawlscope)

Visit each repository for setup instructions, license terms, and contribution details. Browse the [EthosLink GitHub organization](https://github.com/ethos-link) for other public repositories.
