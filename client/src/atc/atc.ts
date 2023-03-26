import { ATCBoard } from "./atcboard";
import { ATCBoardFlight } from "./board/flight";

export interface FlightInterface {
    id     : string;
    name   : string;
    status : "unknown";
}


class ATCDataHandler {

    #atc:ATC;
    #flights:{[key:string]: FlightInterface} = {};

    #updateInterval:number|undefined = undefined;
    #updateIntervalDelay:number      = 1000;


    constructor( atc:ATC ) {

        this.#atc = atc;

    }


    getFlights() {
        return this.#flights;
    }


    startUpdates() {
        
        this.#updateInterval = setInterval( () => {

            fetch( '/api/atc/flight', {
                method: 'GET',      
                headers: { 
                    'Accept': '*/*',
                    'Content-Type': 'application/json' 
                }
            })
            .then( response => response.json() )
            .then( data => {
                this.setFlights( data );
            });

        }, this.#updateIntervalDelay );

    }


    setFlights( flights:{[key:string]: any} ) {

        this.#flights = flights;

    }


    stopUpdates() {
        
        clearInterval( this.#updateInterval );

    }
    
}




export class ATC {

    #boards:ATCBoard[] = [];
    #dataHandler:ATCDataHandler;


    constructor() {
        
        this.#dataHandler = new ATCDataHandler( this );

        this.lookForBoards();

    }


    addBoard<T extends ATCBoard>( board:T ) {

        board.startUpdates();

        this.#boards.push( board );
        
    }


    getDataHandler() {
        return this.#dataHandler;
    }


    lookForBoards() {

        document.querySelectorAll( ".ol-atc-board" ).forEach( board => {

            if ( board instanceof HTMLElement ) {
                this.addBoard( new ATCBoardFlight( this, board ) );
            }

        });

    }

    startUpdates() {

        this.#dataHandler.startUpdates();

    }


    stopUpdates() {

        this.#dataHandler.stopUpdates();

    }

}