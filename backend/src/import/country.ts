/**
 * Country names as one German spelling, whatever the page or the model wrote:
 * "Croatia", "HR", "Hrvatska" and "Kroatien" must not become four groups in a list.
 */
const CODES = "AD AE AF AG AL AM AO AR AT AU AZ BA BB BD BE BF BG BH BJ BM BN BO BR BS BT BW BY BZ CA CD CG CH CI CL CM CN CO CR CU CV CY CZ DE DJ DK DM DO DZ EC EE EG ER ES ET FI FJ FO FR GA GB GD GE GH GI GL GM GN GQ GR GT GW GY HK HN HR HT HU ID IE IL IN IQ IR IS IT JM JO JP KE KG KH KM KR KW KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MG MK ML MM MN MO MR MT MU MV MW MX MY MZ NA NE NG NI NL NO NP NZ OM PA PE PG PH PK PL PR PT PY QA RE RO RS RU RW SA SC SD SE SG SI SK SL SM SN SO SR SV SY SZ TD TG TH TJ TN TR TT TW TZ UA UG US UY UZ VA VE VN XK YE ZA ZM ZW".split(" ");

const key = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z]/g, "");

const table = new Map<string, string>();
{
  const german = new Intl.DisplayNames(["de"], { type: "region" });
  for (const code of CODES) {
    const name = german.of(code);
    if (!name || name === code) continue;
    table.set(key(code), name);
    // The country's name in the languages listings commonly come in, and in its own.
    for (const locale of ["de", "en", "fr", "it", "es", "nl", "da", "sv", "pl", code.toLowerCase()]) {
      try {
        const other = new Intl.DisplayNames([locale], { type: "region" }).of(code);
        if (other && other !== code && !table.has(key(other))) table.set(key(other), name);
      } catch {
        // No such locale: nothing to add.
      }
    }
  }
  const extra: Record<string, string> = { hrvatska: "HR", usa: "US", uk: "GB", england: "GB", greatbritain: "GB", grossbritannien: "GB", holland: "NL", czechia: "CZ", tschechien: "CZ", turkey: "TR", espana: "ES", italia: "IT", ellada: "GR", hellas: "GR", osterreich: "AT", schweiz: "CH", suisse: "CH", svizzera: "CH", danmark: "DK", sverige: "SE", norge: "NO", polska: "PL", magyarorszag: "HU", slovenija: "SI", crnagora: "ME", shqiperia: "AL", deutschland: "DE", nederland: "NL", belgie: "BE", belgique: "BE", portugal: "PT", france: "FR" };
  for (const [k, code] of Object.entries(extra)) table.set(k, german.of(code) ?? code);
}

export function germanCountry(raw: string | null): string | null {
  if (!raw) return raw;
  const trimmed = raw.trim();
  return table.get(key(trimmed)) ?? trimmed;
}

/** Rough outlines (south, north, west, east) of the countries holidays usually go to, islands included. */
const OUTLINES: Record<string, [number, number, number, number]> = {
  Kroatien: [42.3, 46.6, 13.4, 19.5],
  Italien: [35.4, 47.2, 6.6, 18.6],
  Spanien: [27.5, 43.9, -18.3, 4.4],
  Frankreich: [41.3, 51.2, -5.3, 9.7],
  Griechenland: [34.7, 41.8, 19.3, 29.7],
  Portugal: [32.3, 42.2, -31.5, -6.1],
  Deutschland: [47.2, 55.1, 5.8, 15.1],
  Österreich: [46.3, 49.1, 9.5, 17.2],
  Schweiz: [45.8, 47.9, 5.9, 10.5],
  Dänemark: [54.5, 57.8, 8.0, 15.3],
  Niederlande: [50.7, 53.6, 3.3, 7.3],
  Belgien: [49.4, 51.6, 2.5, 6.5],
  Schweden: [55.2, 69.1, 10.9, 24.2],
  Norwegen: [57.9, 71.3, 4.4, 31.2],
  Finnland: [59.7, 70.1, 19.4, 31.6],
  Polen: [49.0, 54.9, 14.1, 24.2],
  Tschechien: [48.5, 51.1, 12.0, 18.9],
  Slowenien: [45.4, 46.9, 13.3, 16.7],
  Ungarn: [45.7, 48.6, 16.1, 22.9],
  Montenegro: [41.8, 43.6, 18.4, 20.4],
  Albanien: [39.6, 42.7, 19.2, 21.1],
  Türkei: [35.8, 42.2, 25.6, 44.9],
  Zypern: [34.5, 35.8, 32.2, 34.7],
  Malta: [35.7, 36.1, 14.1, 14.6],
  Bulgarien: [41.2, 44.3, 22.3, 28.7],
  "Vereinigtes Königreich": [49.8, 60.9, -8.7, 1.8],
  Irland: [51.3, 55.5, -10.7, -5.9],
  Ägypten: [21.9, 31.8, 24.6, 37.0],
  Marokko: [27.6, 36.0, -13.3, -0.9],
  Tunesien: [30.2, 37.6, 7.5, 11.7],
};

/**
 * False only when the position clearly lies outside the country the advert names: pages carry
 * other coordinates too (where the visitor or the server is), and one of those must not become the house.
 */
export function positionFitsCountry(lat: number, lon: number, country: string | null): boolean {
  const box = country ? OUTLINES[germanCountry(country) ?? ""] : undefined;
  if (!box) return true;
  const margin = 0.5;
  return lat >= box[0] - margin && lat <= box[1] + margin && lon >= box[2] - margin && lon <= box[3] + margin;
}
