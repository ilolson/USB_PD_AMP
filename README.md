# USB PD AMP

Static GitHub Pages landing page for the HUB75 Audio Matrix macOS app.

## GitHub Pages

This repository is ready for the classic GitHub Pages flow:

1. Push the repository to GitHub.
2. Open **Settings > Pages**.
3. Under **Build and deployment**, choose **Deploy from a branch**.
4. Select the default branch and `/ (root)`.
5. Save.

GitHub Pages will serve `index.html` from the repository root.

After Pages is enabled, R1 will be available at:

`https://ilolson.github.io/USB_PD_AMP/boards/R1/`

If that URL returns 404, Pages has not been enabled or deployed yet. In this repo,
set Pages to deploy from `main` and `/ (root)`, then wait for the Pages build to finish.

## Boards

- R1 lives in `boards/R1/index.html` and links to `https://ilolson.github.io/USB_PD_AMP/boards/R1/`.
- To add R2, create `boards/R2/index.html`, then add a link to `boards/R2/` in `index.html`.
