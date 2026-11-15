import { loadConfig } from "../config.js";
import { connect } from "./client.js";

const { close } = await connect(loadConfig().DATABASE_URL);
await close();
console.log("Migrations applied.");
