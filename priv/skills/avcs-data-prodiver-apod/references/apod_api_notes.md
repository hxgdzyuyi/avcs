# NASA APOD API Notes

## Endpoint

`GET https://api.nasa.gov/planetary/apod`

## Query parameters

- `api_key`: Your NASA API key, optional in dev use `DEMO_KEY`.
- `date`: Optional date `YYYY-MM-DD` for a specific APOD entry.
- `hd`: Optional legacy client flag in older examples; API response may include `hdurl` regardless.
- `thumbs`: Optional when `media_type=video` to request `thumbnail_url`.

## Response fields used by this skill

- `date`
- `title`
- `explanation`
- `copyright`
- `media_type`
- `url`
- `hdurl` (preferably when `--prefer-hd`)
- `thumbnail_url` (optional fallback metadata)

## Fallback behavior

If `media_type` is not `image`, do not force image download. Return metadata only.
