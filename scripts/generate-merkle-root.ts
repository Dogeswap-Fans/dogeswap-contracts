import { program } from 'commander'
import fs from 'fs'
import { parseBalanceMap } from '../src/parse-balance-map'

program
  .version('0.0.0')
  .requiredOption(
    '-i, --input <path>',
    'input JSON file location containing a map of account addresses to string balances'
  )

program.parse(process.argv)

const json = JSON.parse(fs.readFileSync(program.input, { encoding: 'utf8' }))

if (typeof json !== 'object') throw new Error('Invalid JSON')

let formattedJSON: {
  [account: string]: number
} = {}

for (const key in json) {
  if (Object.prototype.hasOwnProperty.call(json, key)) {
    const element = json[key]
    formattedJSON[key] = element.total
  }
}

const result = JSON.stringify(parseBalanceMap(formattedJSON), null, 4)
const lastIndex = program.input.lastIndexOf('/')
console.log(result)

fs.writeFileSync(`${__dirname}/result-${program.input.substr(lastIndex + 1)}`, result) 